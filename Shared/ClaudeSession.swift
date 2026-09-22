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

    static func resolveCredential(
        manualToken: String? = nil,
        environment: [String: String]? = nil,
        credentialFiles: [URL]? = nil,
        includeKeychain: Bool = true
    ) async throws -> ClaudeCredential {
        let env = environment ?? ProcessInfo.processInfo.environment
        let files = credentialFiles ?? credentialFileURLs()
        var local: ClaudeOAuthCreds?
        var localError: ClaudeSessionError?
        if let creds = credentialsFromFiles(files) {
            local = creds
        } else if includeKeychain {
            do {
                local = try await keychainOAuthCredentials()
            } catch let error as ClaudeSessionError {
                localError = error
            }
        }
        return try selectCredential(
            manualRaw: manualToken ?? loadManualToken(),
            environmentOAuth: environmentOAuthToken(environment: env),
            local: local,
            localError: localError,
            apiKeyFromFiles: loadLocalAPIKey(fileURLs: files),
            environmentAPIKey: environmentAPIKey(environment: env)
        )
    }

    /// 手動トークンと環境変数の OAuth を優先する。ローカル OAuth が期限切れ・欠落・Keychain 拒否でも、API キーがあればそちらを使う。キーが無ければ元のエラーを返す。
    static func selectCredential(
        manualRaw: String?,
        environmentOAuth: String?,
        local: ClaudeOAuthCreds?,
        localError: ClaudeSessionError?,
        apiKeyFromFiles: String?,
        environmentAPIKey: String?
    ) throws -> ClaudeCredential {
        if let token = try oauthTokenFromRaw(manualRaw) {
            return token
        }
        if let token = try oauthTokenFromRaw(environmentOAuth) {
            return token
        }
        let fallbackKey = apiKeyFromFiles ?? environmentAPIKey
        if let local {
            if isAPIKey(local.accessToken) {
                return .apiKey(local.accessToken)
            }
            do {
                try validate(local)
                return .oauth(local)
            } catch let error as ClaudeSessionError {
                return try apiKeyOrRethrow(fallbackKey, error: error)
            }
        }
        if let localError {
            return try apiKeyOrRethrow(fallbackKey, error: localError)
        }
        if let fallbackKey, !fallbackKey.isEmpty {
            return .apiKey(fallbackKey)
        }
        throw ClaudeSessionError.tokenMissing
    }

    private static func apiKeyOrRethrow(_ key: String?, error: ClaudeSessionError) throws -> ClaudeCredential {
        if let key, !key.isEmpty {
            return .apiKey(key)
        }
        throw error
    }

    private static func oauthTokenFromRaw(_ raw: String?) throws -> ClaudeCredential? {
        guard let raw, !raw.isEmpty else { return nil }
        let token = normalizeToken(raw)
        guard !token.isEmpty else { throw ClaudeSessionError.invalidToken }
        if isAPIKey(token) { return .apiKey(token) }
        if isJWTExpired(token) { throw ClaudeSessionError.tokenExpired }
        return .oauth(ClaudeOAuthCreds(accessToken: token, expiresAt: JWT.expiry(token)?.timeIntervalSince1970))
    }

    static func environmentOAuthToken(environment: [String: String]? = nil) -> String? {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let value = env["CLAUDE_CODE_OAUTH_TOKEN"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 手動更新のときだけ、前回の Keychain 拒否／不在をやり直す。成功キャッシュは消さない。
    /// 更新要求は App Group 経由で外からも立てられるので、最短間隔を置いて
    /// Keychain ダイアログの連投（「許可」を押させる誘導）を防ぐ。
    static func retryKeychainAccess(now: Date = Date()) {
        claudeCodeCacheLock.lock()
        defer { claudeCodeCacheLock.unlock() }
        guard shouldDropCache(claudeCodeCredsCache, now: now) else { return }
        guard keychainRetryAllowed(lastRetryAt: lastKeychainRetryAt, now: now) else { return }
        lastKeychainRetryAt = now
        claudeCodeCredsCache = .unset
    }

    /// 期限切れのキャッシュは捨てる。Claude Code を起動し直したあと、アプリを終了せずに
    /// 「更新」で新しいトークンを拾い直せるようにする。有効なキャッシュは消さない
    /// （消すと Keychain ダイアログが再び出る）。unset は次回そのまま試す。
    private static func shouldDropCache(_ cache: ClaudeCodeCredsCache, now: Date) -> Bool {
        switch cache {
        case .unset:
            return false
        case .missing, .denied:
            return true
        case .creds(let creds):
            return isCredsExpired(creds, now: now)
        }
    }

    static let minimumKeychainRetryInterval: TimeInterval = 60

    static func keychainRetryAllowed(
        lastRetryAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = ClaudeSession.minimumKeychainRetryInterval
    ) -> Bool {
        guard let lastRetryAt else { return true }
        return now.timeIntervalSince(lastRetryAt) >= minimumInterval
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

    static func environmentAPIKey(environment: [String: String]? = nil) -> String? {
        let env = environment ?? ProcessInfo.processInfo.environment
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

    static func isCredsExpired(_ creds: ClaudeOAuthCreds, now: Date = Date()) -> Bool {
        isExpired(expiresAt: creds.expiresAt, now: now) || isJWTExpired(creds.accessToken, now: now)
    }

    private static func validate(_ creds: ClaudeOAuthCreds) throws {
        if creds.accessToken.isEmpty { throw ClaudeSessionError.tokenMissing }
        if isCredsExpired(creds) { throw ClaudeSessionError.tokenExpired }
    }

    // MARK: - Local stores

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
        if let creds = credentialsFromFiles(files) {
            return creds
        }
        // 対話プロンプトは `resolveCredential` 側。ここではキャッシュだけ見る。
        return try readCachedKeychainCreds(interactive: interactiveKeychain)
    }

    private static func credentialsFromFiles(_ files: [URL]) -> ClaudeOAuthCreds? {
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
        return nil
    }

    /// テスト用。キーチェーンは見ない。
    static func readCredentialsFile(fileURL: URL) throws -> ClaudeOAuthCreds? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try parseCredentialsJSON(data)
    }

    /// `credentialFileURLs()` を先頭から探す。Keychain の OAuth blob には API キーが無い。
    static func loadLocalAPIKey(fileURLs: [URL]? = nil) -> String? {
        for url in fileURLs ?? credentialFileURLs() {
            if let key = try? readAPIKeyFile(fileURL: url), !key.isEmpty {
                return key
            }
        }
        return nil
    }

    private static func readAPIKeyFile(fileURL: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseAPIKey(from: json)
    }

    /// access token だけを保持する。refresh token を含む生の blob はキャッシュしない。
    private enum ClaudeCodeCredsCache {
        case unset
        case missing
        case denied
        case creds(ClaudeOAuthCreds)
    }

    private enum KeychainCredsResult {
        case creds(ClaudeOAuthCreds)
        case missing
        case denied
    }

    private enum KeychainSecretResult {
        case secret(String)
        case missing
        case denied
    }

    private static let claudeCodeCacheLock = NSLock()
    private static var claudeCodeCredsCache: ClaudeCodeCredsCache = .unset
    private static var lastKeychainRetryAt: Date?

    private static func keychainOAuthCredentials() async throws -> ClaudeOAuthCreds? {
        try await readClaudeCodeKeychainCreds()
    }

    /// プロンプトは出さない。拒否キャッシュは `interactive` のときだけエラーにする。
    private static func readCachedKeychainCreds(interactive: Bool) throws -> ClaudeOAuthCreds? {
        claudeCodeCacheLock.lock()
        defer { claudeCodeCacheLock.unlock() }
        switch claudeCodeCredsCache {
        case .creds(let creds):
            return creds
        case .missing, .unset:
            return nil
        case .denied:
            if interactive { throw ClaudeSessionError.keychainDenied }
            return nil
        }
    }

    /// Claude Code の項目は ACL がこのアプリを含まない。`security` の待ちはメインスレッドの外で行う。
    private static func readClaudeCodeKeychainCreds() async throws -> ClaudeOAuthCreds? {
        if let cached = try readCachedKeychainCreds(interactive: true) {
            return cached
        }
        guard beginKeychainPrompt() else {
            return try readCachedKeychainCreds(interactive: true)
        }
        return try storeKeychainPromptResult(await copyClaudeCodeKeychainCreds())
    }

    private static func beginKeychainPrompt() -> Bool {
        claudeCodeCacheLock.lock()
        defer { claudeCodeCacheLock.unlock() }
        if case .unset = claudeCodeCredsCache { return true }
        return false
    }

    private static func storeKeychainPromptResult(_ result: KeychainCredsResult) throws -> ClaudeOAuthCreds? {
        claudeCodeCacheLock.lock()
        defer { claudeCodeCacheLock.unlock() }
        if case .creds(let existing) = claudeCodeCredsCache {
            return existing
        }
        switch result {
        case .creds(let creds):
            claudeCodeCredsCache = .creds(creds)
            return creds
        case .missing:
            claudeCodeCredsCache = .missing
            return nil
        case .denied:
            claudeCodeCredsCache = .denied
            throw ClaudeSessionError.keychainDenied
        }
    }

    private static func copyClaudeCodeKeychainCreds() async -> KeychainCredsResult {
        let user = NSUserName()
        var denied = false

        /// 生の blob は持ち回さず、その場で access token だけ取り出す。
        func takeIfOAuth(_ raw: String?) -> ClaudeOAuthCreds? {
            guard let raw, let data = raw.data(using: .utf8) else { return nil }
            return oauthCredsIfPresent(in: data)
        }

        // `/usr/bin/security` はターミナルと同じ経路。SecItem はこのアプリの署名だと項目が見えないことがある。
        for service in keychainServiceNames() {
            if let creds = takeIfOAuth(await copyViaSecurityCLI(service: service, account: user)) {
                usageLogger.error("Claude Code credentials loaded via security CLI")
                return .creds(creds)
            }
        }

        await onMain { prepareKeychainPrompt() }
        for service in keychainServiceNames() {
            switch await copySecretResult(service: service, account: user) {
            case .secret(let raw):
                if let creds = takeIfOAuth(raw) { return .creds(creds) }
            case .denied:
                denied = true
            case .missing:
                break
            }
        }

        for item in await listClaudeCodeKeychainItems() {
            if item.account == user { continue }
            switch await copySecretResult(service: item.service, account: item.account) {
            case .denied:
                denied = true
            case .secret(let raw):
                if let creds = takeIfOAuth(raw) { return .creds(creds) }
            case .missing:
                break
            }
        }

        if denied { return .denied }
        usageLogger.error("Claude Code keychain OAuth item not found")
        return .missing
    }

    private static func copySecretResult(service: String, account: String) async -> KeychainSecretResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        switch await copyMatchingClaudeCodeSecret(query) {
        case .secret(let raw):
            return .secret(raw)
        case .denied:
            if let raw = await copyViaSecurityCLI(service: service, account: account) {
                return .secret(raw)
            }
            return .denied
        case .missing:
            if let raw = await copyViaSecurityCLI(service: service, account: account) {
                return .secret(raw)
            }
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let synced = await copyMatchingClaudeCodeSecret(query)
            if case .secret(let raw) = synced { return .secret(raw) }
            return .missing
        }
    }

    private static func listClaudeCodeKeychainItems() async -> [(service: String, account: String)] {
        await offMain { listClaudeCodeKeychainItemsSync() }
    }

    private static func listClaudeCodeKeychainItemsSync() -> [(service: String, account: String)] {
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
    /// 待ちはバックグラウンドで行い、その間メインアクターを解放する。
    private static func copyViaSecurityCLI(service: String, account: String) async -> String? {
        guard Bundle.main.bundleIdentifier == "jp.shigeya.AIUsageWidget" else { return nil }
        guard !account.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: copyViaSecurityCLIBlocking(service: service, account: account))
            }
        }
    }

    private static func copyViaSecurityCLIBlocking(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
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

    /// `NSApp.activate` だけメインで行う。
    private static func onMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// `SecItemCopyMatching` はダイアログのあいだ呼び出し側を塞ぐ。メインでは呼ばない。
    private static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func copyMatchingClaudeCodeSecret(_ query: [String: Any]) async -> KeychainSecretResult {
        await offMain { copyMatchingClaudeCodeSecretSync(query) }
    }

    private static func copyMatchingClaudeCodeSecretSync(_ query: [String: Any]) -> KeychainSecretResult {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let secret = String(data: data, encoding: .utf8) {
            return .secret(secret)
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
