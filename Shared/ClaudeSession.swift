import Foundation
import Security
import AppKit
import CryptoKit

enum ClaudeSessionError: LocalizedError, Equatable {
    case tokenMissing
    case tokenExpired
    case invalidToken
    case apiKeyMode
    case keychainDenied

    var errorDescription: String? {
        switch self {
        case .tokenMissing: return "No Claude Code OAuth token"
        case .tokenExpired: return "Claude Code OAuth token expired"
        case .invalidToken: return "Invalid Claude OAuth token"
        case .apiKeyMode: return "Claude is using an API key, not a subscription OAuth login"
        case .keychainDenied: return "Claude Code keychain access denied"
        }
    }
}

struct ClaudeOAuthCreds: Equatable {
    var accessToken: String
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var email: String?
}

enum ClaudeCredential: Equatable {
    case oauth(ClaudeOAuthCreds)
    case apiKey(String)
}

/// Claude Code のローカル資格情報を読む。リフレッシュトークンは使わず、書き戻しもしない。
enum ClaudeSession {
    private static let manualService = "jp.shigeya.AIUsageWidget.claude"
    private static let manualAccount = "claudeAiOauthAccessToken"

    static func resolveCredential() throws -> ClaudeCredential {
        if let token = try oauthTokenFromRaw(loadManualToken()) {
            return token
        }
        if let token = try oauthTokenFromRaw(environmentOAuthToken()) {
            return token
        }
        do {
            if let creds = try loadLocalCredentials() {
                if isAPIKey(creds.accessToken) {
                    return .apiKey(creds.accessToken)
                }
                try validate(creds)
                return .oauth(creds)
            }
        } catch ClaudeSessionError.apiKeyMode {
            if let key = try loadLocalAPIKey() ?? environmentAPIKey() {
                return .apiKey(key)
            }
            throw ClaudeSessionError.apiKeyMode
        }
        if let key = try loadLocalAPIKey() ?? environmentAPIKey() {
            return .apiKey(key)
        }
        throw ClaudeSessionError.tokenMissing
    }

    static func hasAnyCredential() -> Bool {
        if let manual = loadManualToken(), !manual.isEmpty { return true }
        if let token = environmentOAuthToken(), !token.isEmpty { return true }
        if let creds = try? loadLocalCredentials(interactiveKeychain: false), !creds.accessToken.isEmpty { return true }
        if let key = try? loadLocalAPIKey(interactiveKeychain: false), !key.isEmpty { return true }
        if let key = environmentAPIKey(), !key.isEmpty { return true }
        return false
    }

    private static func oauthTokenFromRaw(_ raw: String?) throws -> ClaudeCredential? {
        guard let raw, !raw.isEmpty else { return nil }
        let token = normalizeToken(raw)
        guard !token.isEmpty else { throw ClaudeSessionError.invalidToken }
        if isAPIKey(token) { return .apiKey(token) }
        if isJWTExpired(token) { throw ClaudeSessionError.tokenExpired }
        return .oauth(ClaudeOAuthCreds(accessToken: token, expiresAt: JWT.expiry(token)?.timeIntervalSince1970))
    }

    static func environmentOAuthToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["CLAUDE_CODE_OAUTH_TOKEN"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 手動更新のときだけ、前回の Keychain 拒否をやり直す。成功キャッシュは消さない。
    static func retryKeychainAccess() {
        claudeCodeBlobLock.lock()
        defer { claudeCodeBlobLock.unlock() }
        if case .blob = claudeCodeBlobCache { return }
        claudeCodeBlobCache = .unset
    }

    static func saveManualToken(_ raw: String) throws {
        let token = normalizeToken(raw)
        guard !token.isEmpty else { throw ClaudeSessionError.invalidToken }
        try storeKeychain(token)
    }

    static func clearManualToken() {
        deleteKeychain()
    }

    static func loadManualToken() -> String? {
        readKeychain()
    }

    // MARK: - Normalize / parse (pure)

    /// 貼り付け値から access token だけを取り出す。JSON ごと貼っても refresh token は使わない。
    static func normalizeToken(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("{"), let data = value.data(using: .utf8) {
            if let creds = try? parseCredentialsJSON(data) {
                return creds.accessToken
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let key = parseAPIKey(from: json)
            {
                return key
            }
        }
        return value
    }

    static func isAPIKey(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Claude Code OAuth は `sk-ant-oat-` だけでなく `sk-ant-oat01-` もある。
        if value.hasPrefix("sk-ant-oat") { return false }
        return value.hasPrefix("sk-ant-")
    }

    static func parseAPIKey(from json: [String: Any]) -> String? {
        let candidates = [
            json["apiKey"] as? String,
            json["api_key"] as? String,
            json["ANTHROPIC_API_KEY"] as? String,
            json["ANTHROPIC_ADMIN_KEY"] as? String,
            json["anthropic_api_key"] as? String
        ]
        for raw in candidates {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isAPIKey(trimmed) { return trimmed }
        }
        return nil
    }

    static func environmentAPIKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["ANTHROPIC_ADMIN_KEY", "ANTHROPIC_ADMIN_API_KEY", "ANTHROPIC_API_KEY"] {
            if let value = env[name] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if isAPIKey(trimmed) { return trimmed }
            }
        }
        return nil
    }

    static func parseCredentialsJSON(_ data: Data) throws -> ClaudeOAuthCreds {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeSessionError.invalidToken
        }
        // claudeAiOauth を優先。mcpOAuth 配下の accessToken はプラグイン用なので使わない。
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let creds = oAuthCreds(from: oauth, email: (json["email"] as? String) ?? (oauth["email"] as? String))
        {
            return creds
        }
        if let creds = oAuthCreds(from: json, email: json["email"] as? String) {
            return creds
        }
        if json["mcpOAuth"] != nil {
            throw ClaudeSessionError.apiKeyMode
        }
        throw ClaudeSessionError.tokenMissing
    }

    /// 指定した辞書の直下だけを見る。入れ子の mcpOAuth は見ない。
    static func oAuthCreds(from oauth: [String: Any], email: String?) -> ClaudeOAuthCreds? {
        let token = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String)
            ?? ""
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expires: Double?
        if let value = oauth["expiresAt"] as? Double {
            expires = value
        } else if let value = oauth["expiresAt"] as? Int {
            expires = Double(value)
        } else if let value = oauth["expires_at"] as? Double {
            expires = value
        } else {
            expires = nil
        }
        return ClaudeOAuthCreds(
            accessToken: trimmed,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            email: email ?? (oauth["email"] as? String)
        )
    }

    static func oauthCredsIfPresent(in data: Data) -> ClaudeOAuthCreds? {
        guard let creds = try? parseCredentialsJSON(data), !creds.accessToken.isEmpty else { return nil }
        if isAPIKey(creds.accessToken) { return nil }
        return creds
    }

    /// `expiresAt` はミリ秒（13桁）または秒。60秒の余裕を見る。
    static func isExpired(expiresAt: Double?, now: Date = Date()) -> Bool {
        guard let expiresAt, expiresAt > 0 else { return false }
        let seconds = expiresAt >= 1e11 ? expiresAt / 1000.0 : expiresAt
        return seconds <= now.timeIntervalSince1970 + 60
    }

    static func isJWTExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = JWT.expiry(token) else { return false }
        return expiry.timeIntervalSince(now) <= 60
    }

    private static func validate(_ creds: ClaudeOAuthCreds) throws {
        if creds.accessToken.isEmpty { throw ClaudeSessionError.tokenMissing }
        if isExpired(expiresAt: creds.expiresAt) { throw ClaudeSessionError.tokenExpired }
        if isJWTExpired(creds.accessToken) { throw ClaudeSessionError.tokenExpired }
    }

    // MARK: - Local stores

    static var defaultCredentialsURL: URL {
        credentialFileURLs().first ?? CursorSession.realHomeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    static func credentialFileURLs() -> [URL] {
        let home = CursorSession.realHomeDirectory
        var urls: [URL] = []
        func add(_ url: URL) {
            if !urls.contains(url) { urls.append(url) }
        }
        for name in ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"] {
            if let dir = ProcessInfo.processInfo.environment[name], !dir.isEmpty {
                let base = URL(fileURLWithPath: dir, isDirectory: true)
                add(base.appendingPathComponent(".credentials.json"))
                add(base.appendingPathComponent("credentials.json"))
            }
        }
        add(home.appendingPathComponent(".claude/.credentials.json"))
        add(home.appendingPathComponent(".claude/credentials.json"))
        add(home.appendingPathComponent(".config/claude/credentials.json"))
        return urls
    }

    /// Claude Code 2.1+ は `Claude Code-credentials` または `…-<sha256(configDir)[0..<8]>`。
    static func keychainServiceNames(configDir: String? = nil) -> [String] {
        var names = ["Claude Code-credentials", "Claude Code"]
        let dirs = [
            configDir,
            ProcessInfo.processInfo.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"],
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        ].compactMap { $0 }.filter { !$0.isEmpty }
        for dir in dirs {
            let suffix = keychainConfigSuffix(forConfigDir: dir)
            names.insert("Claude Code-credentials\(suffix)", at: 0)
        }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return unique
    }

    static func keychainConfigSuffix(forConfigDir dir: String) -> String {
        let nfc = dir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(nfc.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "-" + String(hex.prefix(8))
    }

    static func loadLocalCredentials(
        fileURL: URL? = nil,
        interactiveKeychain: Bool = true
    ) throws -> ClaudeOAuthCreds? {
        let files = fileURL.map { [$0] } ?? credentialFileURLs()
        for url in files {
            do {
                if let creds = try readCredentialsFile(fileURL: url), !creds.accessToken.isEmpty {
                    return creds
                }
            } catch ClaudeSessionError.apiKeyMode {
                continue
            } catch {
                continue
            }
        }
        guard let blob = try readClaudeCodeKeychainBlob(interactive: interactiveKeychain),
              let data = blob.data(using: .utf8)
        else {
            return nil
        }
        return try parseCredentialsJSON(data)
    }

    /// テスト用。キーチェーンは見ない。
    static func readCredentialsFile(fileURL: URL) throws -> ClaudeOAuthCreds? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try parseCredentialsJSON(data)
    }

    static func loadLocalAPIKey(
        fileURL: URL = defaultCredentialsURL,
        interactiveKeychain: Bool = true
    ) throws -> String? {
        if let key = try readAPIKeyFile(fileURL: fileURL) {
            return key
        }
        guard let blob = try readClaudeCodeKeychainBlob(interactive: interactiveKeychain),
              let data = blob.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return parseAPIKey(from: json)
    }

    private static func readAPIKeyFile(fileURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseAPIKey(from: json)
    }

    private enum ClaudeCodeBlobCache {
        case unset
        case missing
        case denied
        case blob(String)
    }

    private enum KeychainCopyResult {
        case blob(String)
        case missing
        case denied
    }

    private static let claudeCodeBlobLock = NSLock()
    private static var claudeCodeBlobCache: ClaudeCodeBlobCache = .unset

    /// Claude Code の項目は ACL がこのアプリを含まない。ダイアログはメインスレッドで一度だけ出す。
    private static func readClaudeCodeKeychainBlob(interactive: Bool) throws -> String? {
        claudeCodeBlobLock.lock()
        switch claudeCodeBlobCache {
        case .blob(let blob):
            claudeCodeBlobLock.unlock()
            return blob
        case .missing:
            claudeCodeBlobLock.unlock()
            return nil
        case .denied:
            claudeCodeBlobLock.unlock()
            if interactive { throw ClaudeSessionError.keychainDenied }
            return nil
        case .unset:
            claudeCodeBlobLock.unlock()
        }

        guard interactive else { return nil }

        let result = copyClaudeCodeKeychainBlob()
        claudeCodeBlobLock.lock()
        if case .blob(let existing) = claudeCodeBlobCache {
            claudeCodeBlobLock.unlock()
            return existing
        }
        switch result {
        case .blob(let blob):
            claudeCodeBlobCache = .blob(blob)
            claudeCodeBlobLock.unlock()
            return blob
        case .missing:
            claudeCodeBlobCache = .missing
            claudeCodeBlobLock.unlock()
            return nil
        case .denied:
            claudeCodeBlobCache = .denied
            claudeCodeBlobLock.unlock()
            throw ClaudeSessionError.keychainDenied
        }
    }

    private static func copyClaudeCodeKeychainBlob() -> KeychainCopyResult {
        let user = NSUserName()
        var denied = false

        func takeIfOAuth(_ raw: String?) -> String? {
            guard let raw, let data = raw.data(using: .utf8) else { return nil }
            return oauthCredsIfPresent(in: data) == nil ? nil : raw
        }

        // `/usr/bin/security` はターミナルと同じ経路。SecItem はこのアプリの署名だと項目が見えないことがある。
        for service in keychainServiceNames() {
            if let blob = takeIfOAuth(copyViaSecurityCLI(service: service, account: user)) {
                usageLogger.error("Claude Code credentials loaded via security CLI")
                return .blob(blob)
            }
        }

        prepareKeychainPrompt()
        for service in keychainServiceNames() {
            switch copySecretResult(service: service, account: user) {
            case .blob(let raw):
                if let blob = takeIfOAuth(raw) { return .blob(blob) }
            case .denied:
                denied = true
            case .missing:
                break
            }
        }

        for item in listClaudeCodeKeychainItems() {
            if item.account == user { continue }
            switch copySecretResult(service: item.service, account: item.account) {
            case .denied:
                denied = true
            case .blob(let raw):
                if let blob = takeIfOAuth(raw) { return .blob(blob) }
            case .missing:
                break
            }
        }

        if denied { return .denied }
        usageLogger.error("Claude Code keychain OAuth item not found")
        return .missing
    }

    private static func copySecretResult(service: String, account: String) -> KeychainCopyResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        switch copyMatchingClaudeCodeBlob(query) {
        case .blob(let raw):
            return .blob(raw)
        case .denied:
            if let raw = copyViaSecurityCLI(service: service, account: account) {
                return .blob(raw)
            }
            return .denied
        case .missing:
            if let raw = copyViaSecurityCLI(service: service, account: account) {
                return .blob(raw)
            }
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let synced = copyMatchingClaudeCodeBlob(query)
            if case .blob(let raw) = synced { return .blob(raw) }
            return .missing
        }
    }

    private static func listClaudeCodeKeychainItems() -> [(service: String, account: String)] {
        var found: [(String, String)] = []
        for service in keychainServiceNames() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess else { continue }
            let rows: [[String: Any]]
            if let many = item as? [[String: Any]] {
                rows = many
            } else if let one = item as? [String: Any] {
                rows = [one]
            } else {
                continue
            }
            for row in rows {
                let account = row[kSecAttrAccount as String] as? String ?? ""
                found.append((service, account))
            }
        }
        return found
    }

    /// `security find-generic-password -a $USER -s … -w` は SecItem より対話ダイアログが出やすい。
    private static func copyViaSecurityCLI(service: String, account: String) -> String? {
        guard Bundle.main.bundleIdentifier == "jp.shigeya.AIUsageWidget" else { return nil }
        guard !account.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            usageLogger.error("security CLI failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard process.terminationStatus == 0 else {
            if process.terminationStatus != 44 {
                usageLogger.error("security CLI exit=\(process.terminationStatus, privacy: .public)")
            }
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func prepareKeychainPrompt() {
        guard Bundle.main.bundleIdentifier == "jp.shigeya.AIUsageWidget" else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func copyMatchingClaudeCodeBlob(_ query: [String: Any]) -> KeychainCopyResult {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { copyMatchingClaudeCodeBlobOnMain(query) }
        }
        return copyMatchingClaudeCodeBlobOnMain(query)
    }

    private static func copyMatchingClaudeCodeBlobOnMain(_ query: [String: Any]) -> KeychainCopyResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let blob = String(data: data, encoding: .utf8) {
            return .blob(blob)
        }
        if status == errSecItemNotFound || status == errSecParam {
            return .missing
        }
        usageLogger.error("Claude Code keychain status=\(status, privacy: .public)")
        switch status {
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecNotAvailable:
            return .denied
        default:
            return .denied
        }
    }

    private static func storeKeychain(_ value: String) throws {
        deleteKeychain()
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualService,
            kSecAttrAccount as String: manualAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClaudeSessionError.invalidToken }
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualService,
            kSecAttrAccount as String: manualAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualService,
            kSecAttrAccount as String: manualAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
