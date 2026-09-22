import Foundation
import Security
import SQLite3
import Darwin

enum CursorSessionError: LocalizedError, Equatable {
    case databaseMissing
    case databaseOpenFailed
    case tokenMissing
    case tokenExpired
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .databaseMissing: return "Cursor state database not found"
        case .databaseOpenFailed: return "Could not open Cursor state database"
        case .tokenMissing: return "No Cursor access token in local state"
        case .tokenExpired: return "Cursor access token expired"
        case .invalidToken: return "Invalid Cursor access token"
        }
    }
}

/// Cursor.app のローカルセッションと手動 Cookie を解決する。
enum CursorSession {
    private static let keychainService = "jp.shigeya.AIUsageWidget.cursor"
    private static let keychainAccount = "WorkosCursorSessionToken"
    private static let accessTokenKey = "cursorAuth/accessToken"

    /// サンドボックスでは `homeDirectoryForCurrentUser` がコンテナ内になる。
    /// temporary-exception の実ホーム相対パスを使うには passwd のホームが必要。
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var defaultStateDBURL: URL {
        realHomeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Cookie ヘッダ値（`user_…%3A%3AeyJ…` 形式）を返す。
    static func resolveCookieValue() throws -> String {
        if let manual = loadManualCookie(), !manual.isEmpty {
            return normalizeCookieValue(manual)
        }
        return try cookieFromAppState()
    }

    static func saveManualCookie(_ raw: String) throws {
        let normalized = normalizeCookieValue(raw)
        guard !normalized.isEmpty else { throw CursorSessionError.invalidToken }
        // 簡易検証: JWT 部分があること
        _ = try parseCookieParts(normalized)
        try storeKeychain(normalized)
    }

    static func clearManualCookie() {
        deleteKeychain()
    }

    static func loadManualCookie() -> String? {
        readKeychain()
    }

    // MARK: - App state

    static func cookieFromAppState(dbURL: URL = defaultStateDBURL) throws -> String {
        let jwt = try readAccessToken(from: dbURL)
        guard let expiry = jwtExpiry(jwt), expiry.timeIntervalSinceNow > 60 else {
            throw CursorSessionError.tokenExpired
        }
        // Cursor の JWT `sub` は `auth0|user_…`。Workos cookie は `user_…%3A%3Ajwt`。
        let userID = try cookieUserID(fromJWTSubject: jwtSubject(jwt))
        return "\(userID)%3A%3A\(jwt)"
    }

    /// `auth0|user_01…` / `auth0%7Cuser_01…` → `user_01…`。パイプ無しならそのまま。
    static func cookieUserID(fromJWTSubject sub: String) throws -> String {
        let decoded = sub
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%7c", with: "|")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { throw CursorSessionError.invalidToken }
        if let pipe = decoded.firstIndex(of: "|") {
            let tail = String(decoded[decoded.index(after: pipe)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else { throw CursorSessionError.invalidToken }
            return tail
        }
        return decoded
    }

    static func readAccessToken(from dbURL: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw CursorSessionError.databaseMissing
        }

        // immutable=1 は WAL を見ない。トークン更新の直後は新しい JWT が WAL にしかなく、
        // 先に immutable が成功すると期限切れの古いトークンを掴む。
        // 通常の読みが開けたときの tokenMissing はサインアウトなので、ここで終える。
        // 開けないときだけ immutable、それも無理なときだけコピーする（54MB 級の DB を毎分コピーしない）。
        switch openAccessToken(dbURL: dbURL, immutable: false) {
        case .token(let token):
            return token
        case .missing:
            throw CursorSessionError.tokenMissing
        case .openFailed:
            break
        }

        switch openAccessToken(dbURL: dbURL, immutable: true) {
        case .token(let token):
            return token
        case .missing:
            throw CursorSessionError.tokenMissing
        case .openFailed:
            break
        }

        return try readAccessTokenViaTempCopy(dbURL: dbURL)
    }

    private enum AccessTokenOpen {
        case token(String)
        case missing
        case openFailed
    }

    private static func openAccessToken(dbURL: URL, immutable: Bool) -> AccessTokenOpen {
        do {
            return .token(try readAccessTokenOpening(dbURL: dbURL, immutable: immutable))
        } catch CursorSessionError.tokenMissing {
            return .missing
        } catch {
            return .openFailed
        }
    }

    /// コピーは access token を含む DB 丸ごとなので、専用ディレクトリ（0700）に 0600 で置く。
    /// `copyItem` はコピー元の権限（通常 0644）を引き継ぐため、明示的に絞る。
    /// 前回の異常終了で残ったコピーはここで片付ける。
    private static func readAccessTokenViaTempCopy(dbURL: URL) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aiusage-cursor-state", isDirectory: true)
        try? fm.removeItem(at: dir)
        defer { try? fm.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent("\(UUID().uuidString).vscdb")
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.copyItem(at: dbURL, to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        } catch {
            usageLogger.error("session db copy failed: \(error.localizedDescription, privacy: .public)")
            throw CursorSessionError.databaseOpenFailed
        }
        return try readAccessTokenOpening(dbURL: tmp, immutable: true)
    }

    private static func readAccessTokenOpening(dbURL: URL, immutable: Bool) throws -> String {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let uri = sqliteURI(for: dbURL, immutable: immutable)
        let openResult = sqlite3_open_v2(uri, &db, flags, nil)
        guard openResult == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open rc=\(openResult)"
            sqlite3_close(db)
            usageLogger.debug(
                "session db open failed immutable=\(immutable) msg=\(msg, privacy: .public)"
            )
            throw CursorSessionError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let msg = String(cString: sqlite3_errmsg(db))
            usageLogger.debug("session db prepare failed: \(msg, privacy: .public)")
            throw CursorSessionError.databaseOpenFailed
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, accessTokenKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CursorSessionError.tokenMissing
        }

        if let cString = sqlite3_column_text(statement, 0) {
            let text = String(cString: cString)
            if !text.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        let blob = sqlite3_column_blob(statement, 0)
        let bytes = sqlite3_column_bytes(statement, 0)
        guard let blob, bytes > 0 else { throw CursorSessionError.tokenMissing }
        let data = Data(bytes: blob, count: Int(bytes))
        if let utf8 = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !utf8.isEmpty
        {
            return utf8
        }
        // BOM なし UTF-16LE
        if data.count % 2 == 0,
           let utf16 = String(data: data, encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !utf16.isEmpty
        {
            return utf16.filter { $0 != "\0" }
        }
        throw CursorSessionError.tokenMissing
    }

    /// SQLite URI。パス内スペースなどを percent-encode する。
    private static func sqliteURI(for dbURL: URL, immutable: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let encodedPath = dbURL.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? dbURL.path
        if immutable {
            return "file://\(encodedPath)?mode=ro&immutable=1"
        }
        return "file://\(encodedPath)?mode=ro"
    }

    // MARK: - Cookie parsing

    static func normalizeCookieValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if let range = value.range(of: "WorkosCursorSessionToken=", options: .caseInsensitive) {
            value = String(value[range.upperBound...])
            if let semi = value.firstIndex(of: ";") {
                value = String(value[..<semi])
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // `user::jwt` → URL-encoded form
        if value.contains("::"), !value.contains("%3A%3A") {
            value = value.replacingOccurrences(of: "::", with: "%3A%3A")
        }
        // bare JWT: try to attach cookie user id (IdP prefix を落とす)
        if !value.contains("%3A%3A"), value.split(separator: ".").count == 3,
           let sub = try? jwtSubject(value),
           let userID = try? cookieUserID(fromJWTSubject: sub)
        {
            value = "\(userID)%3A%3A\(value)"
        }
        // 手動貼り付けで `auth0|user_…%3A%3A…` が来ても正規化
        if value.contains("%3A%3A") {
            let parts = value.components(separatedBy: "%3A%3A")
            if parts.count == 2,
               let userID = try? cookieUserID(fromJWTSubject: parts[0]),
               !parts[1].isEmpty
            {
                value = "\(userID)%3A%3A\(parts[1])"
            }
        }
        return value
    }

    static func parseCookieParts(_ cookie: String) throws -> (userID: String, jwt: String) {
        let normalized = normalizeCookieValue(cookie)
        let parts = normalized.components(separatedBy: "%3A%3A")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw CursorSessionError.invalidToken
        }
        return (parts[0], parts[1])
    }

    static func jwtSubject(_ jwt: String) throws -> String {
        try JWT.subject(jwt)
    }

    static func jwtExpiry(_ jwt: String) -> Date? {
        JWT.expiry(jwt)
    }

    // MARK: - Keychain

    private static func storeKeychain(_ value: String) throws {
        deleteKeychain()
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CursorSessionError.invalidToken
        }
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
