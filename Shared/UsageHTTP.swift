import Foundation

/// 使用量取得用の HTTP セッション。
///
/// `URLSession.shared` は応答の `Set-Cookie` を共有クッキーストアへ永続化し（`~/Library/Cookies` に平文）、
/// 応答本体も `URLCache` に残す。Cookie / access token は Keychain だけで持つ方針なので、
/// ディスクに何も残らないセッションを使う。Cookie ヘッダは各 Provider が自分で組み立てる。
enum UsageHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
