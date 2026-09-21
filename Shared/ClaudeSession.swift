import Foundation
import Security

enum ClaudeSessionError: LocalizedError, Equatable {
    case tokenMissing
    case tokenExpired
    case invalidToken
    case apiKeyMode

    var errorDescription: String? {
        switch self {
        case .tokenMissing: return "No Claude Code OAuth token"
        case .tokenExpired: return "Claude Code OAuth token expired"
        case .invalidToken: return "Invalid Claude OAuth token"
        case .apiKeyMode: return "Claude is using an API key, not a subscription OAuth login"
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
    private static let claudeCodeKeychainService = "Claude Code-credentials"

    static func resolveCredential() throws -> ClaudeCredential {
        if let manual = loadManualToken(), !manual.isEmpty {
            let token = normalizeToken(manual)
            guard !token.isEmpty else { throw ClaudeSessionError.invalidToken }
            if isAPIKey(token) { return .apiKey(token) }
            if isJWTExpired(token) { throw ClaudeSessionError.tokenExpired }
            return .oauth(ClaudeOAuthCreds(accessToken: token, expiresAt: JWT.expiry(token)?.timeIntervalSince1970))
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
        if let creds = try? loadLocalCredentials(), !creds.accessToken.isEmpty { return true }
        if let key = try? loadLocalAPIKey(), !key.isEmpty { return true }
        if let key = environmentAPIKey(), !key.isEmpty { return true }
        return false
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
        if value.hasPrefix("sk-ant-oat-") { return false }
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
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        let token = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String)
            ?? ""
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if json["mcpOAuth"] != nil {
                throw ClaudeSessionError.apiKeyMode
            }
            throw ClaudeSessionError.tokenMissing
        }
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
            email: (oauth["email"] as? String) ?? (json["email"] as? String)
        )
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
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(".credentials.json")
        }
        return CursorSession.realHomeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    static func loadLocalCredentials(fileURL: URL = defaultCredentialsURL) throws -> ClaudeOAuthCreds? {
        if let blob = readClaudeCodeKeychainBlob(),
           let data = blob.data(using: .utf8)
        {
            do {
                return try parseCredentialsJSON(data)
            } catch ClaudeSessionError.apiKeyMode {
                throw ClaudeSessionError.apiKeyMode
            } catch {
                // キーチェーンが壊れていても ~/.claude/.credentials.json を試す
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try parseCredentialsJSON(data)
    }

    /// テスト用。キーチェーンは見ない。
    static func readCredentialsFile(fileURL: URL) throws -> ClaudeOAuthCreds? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try parseCredentialsJSON(data)
    }

    static func loadLocalAPIKey(fileURL: URL = defaultCredentialsURL) throws -> String? {
        if let blob = readClaudeCodeKeychainBlob(),
           let data = blob.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = parseAPIKey(from: json)
        {
            return key
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseAPIKey(from: json)
    }

    private static func readClaudeCodeKeychainBlob() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
