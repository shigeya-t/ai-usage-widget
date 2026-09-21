import Foundation
import Security

enum ChatGPTSessionError: LocalizedError, Equatable {
    case tokenMissing
    case tokenExpired
    case invalidToken
    case apiKeyMode

    var errorDescription: String? {
        switch self {
        case .tokenMissing: return "No Codex ChatGPT access token"
        case .tokenExpired: return "Codex ChatGPT access token expired"
        case .invalidToken: return "Invalid ChatGPT access token"
        case .apiKeyMode: return "Codex is using an API key, not a ChatGPT subscription login"
        }
    }
}

struct ChatGPTAuth: Equatable {
    var accessToken: String
    var accountID: String?
    var email: String?
    var planType: String?
}

/// Codex CLI / ChatGPT のローカル資格情報を読む。auth.json への書き戻しと refresh はしない。
enum ChatGPTSession {
    private static let manualService = "jp.shigeya.AIUsageWidget.chatgpt"
    private static let manualAccount = "ChatGPTAccessToken"

    static func resolveAuth() throws -> ChatGPTAuth {
        if let manual = loadManualToken(), !manual.isEmpty {
            let token = normalizeToken(manual)
            guard !token.isEmpty else { throw ChatGPTSessionError.invalidToken }
            if isExpired(token) { throw ChatGPTSessionError.tokenExpired }
            return authFromAccessToken(token)
        }
        guard let auth = try readCodexAuth() else {
            throw ChatGPTSessionError.tokenMissing
        }
        if auth.accessToken.isEmpty { throw ChatGPTSessionError.tokenMissing }
        if isExpired(auth.accessToken) { throw ChatGPTSessionError.tokenExpired }
        return auth
    }

    static func hasAnyCredential() -> Bool {
        if let manual = loadManualToken(), !manual.isEmpty { return true }
        if let auth = try? readCodexAuth(), !auth.accessToken.isEmpty { return true }
        return false
    }

    static func saveManualToken(_ raw: String) throws {
        let token = normalizeToken(raw)
        guard !token.isEmpty else { throw ChatGPTSessionError.invalidToken }
        try storeKeychain(token)
    }

    static func clearManualToken() {
        deleteKeychain()
    }

    static func loadManualToken() -> String? {
        readKeychain()
    }

    // MARK: - Normalize / parse (pure)

    static func normalizeToken(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("{"), let data = value.data(using: .utf8),
           let auth = try? parseAuthJSON(data)
        {
            return auth.accessToken
        }
        return value
    }

    static func parseAuthJSON(_ data: Data) throws -> ChatGPTAuth {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTSessionError.invalidToken
        }
        let tokens = json["tokens"] as? [String: Any]
        let access = (tokens?["access_token"] as? String)
            ?? (json["access_token"] as? String)
            ?? ""
        let trimmed = access.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if (json["OPENAI_API_KEY"] as? String)?.isEmpty == false
                || (json["openai_api_key"] as? String)?.isEmpty == false
            {
                throw ChatGPTSessionError.apiKeyMode
            }
            throw ChatGPTSessionError.tokenMissing
        }
        let explicitAccount = (tokens?["account_id"] as? String)
            ?? (json["account_id"] as? String)
        let idToken = (tokens?["id_token"] as? String) ?? (json["id_token"] as? String)
        return enrich(accessToken: trimmed, explicitAccountID: explicitAccount, idToken: idToken)
    }

    static func authFromAccessToken(_ token: String) -> ChatGPTAuth {
        enrich(accessToken: token, explicitAccountID: nil, idToken: nil)
    }

    static func enrich(accessToken: String, explicitAccountID: String?, idToken: String?) -> ChatGPTAuth {
        let account = accountID(fromAccessToken: accessToken, idToken: idToken, explicit: explicitAccountID)
        let email = JWT.nestedString(accessToken, path: ["https://api.openai.com/profile", "email"])
            ?? JWT.nestedString(idToken ?? "", path: ["https://api.openai.com/profile", "email"])
            ?? JWT.nestedString(accessToken, path: ["email"])
        let plan = JWT.nestedString(accessToken, path: ["https://api.openai.com/auth", "chatgpt_plan_type"])
            ?? JWT.nestedString(idToken ?? "", path: ["https://api.openai.com/auth", "chatgpt_plan_type"])
        return ChatGPTAuth(
            accessToken: accessToken,
            accountID: account,
            email: email,
            planType: plan
        )
    }

    static func accountID(fromAccessToken accessToken: String, idToken: String?, explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let fromAccess = JWT.nestedString(accessToken, path: ["https://api.openai.com/auth", "chatgpt_account_id"]),
           !fromAccess.isEmpty
        {
            return fromAccess
        }
        if let idToken,
           let fromID = JWT.nestedString(idToken, path: ["https://api.openai.com/auth", "chatgpt_account_id"]),
           !fromID.isEmpty
        {
            return fromID
        }
        return nil
    }

    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let expiry = JWT.expiry(token) else { return false }
        return expiry.timeIntervalSince(now) <= 60
    }

    // MARK: - Local stores

    static var defaultAuthURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return CursorSession.realHomeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("auth.json")
    }

    static func readCodexAuth(fileURL: URL = defaultAuthURL) throws -> ChatGPTAuth? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try parseAuthJSON(data)
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
        guard status == errSecSuccess else { throw ChatGPTSessionError.invalidToken }
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
