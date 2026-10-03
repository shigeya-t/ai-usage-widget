import Foundation

enum UsageAPIError: LocalizedError {
    case unauthorized
    case httpStatus(Int)
    case decodeFailed
    /// `retryAfter` は応答の `Retry-After`（秒）。無い・0 のときは nil。
    case rateLimited(retryAfter: TimeInterval?)
    case apiKeyMode

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "unauthorized"
        case .httpStatus(let code): return "HTTP \(code)"
        case .decodeFailed: return "decode failed"
        case .rateLimited: return "rate limited"
        case .apiKeyMode: return "api key mode"
        }
    }

    /// 429 の応答から作る。
    static func rateLimited(_ response: HTTPURLResponse, now: Date = Date()) -> UsageAPIError {
        .rateLimited(retryAfter: RateLimitBackoff.retryAfter(
            header: response.value(forHTTPHeaderField: "Retry-After"),
            now: now
        ))
    }
}

typealias CursorAPIError = UsageAPIError

/// 429 を受けたプロバイダを、しばらく自動更新から外す。
///
/// Claude の `/api/oauth/usage` は短い間隔で叩き続けると `retry-after: 0` の 429 を返し続け、
/// 5 分おきの再試行では何時間も抜けない。`Retry-After` があればそれに従い、無ければ
/// 10 分から倍々に空けて 60 分で頭打ちにする。成功したら戻す。
struct RateLimitBackoff {
    static let baseDelay: TimeInterval = 10 * 60
    static let maxDelay: TimeInterval = 60 * 60
    static let minDelay: TimeInterval = 60

    private struct Entry {
        var strikes: Int
        var until: Date
    }

    private var entries: [String: Entry] = [:]

    /// `providerID` を今は取りに行かないほうがよいか。
    func isCoolingDown(_ providerID: String, now: Date) -> Bool {
        guard let entry = entries[providerID] else { return false }
        return now < entry.until
    }

    func cooldownEnd(_ providerID: String) -> Date? {
        entries[providerID]?.until
    }

    mutating func recordRateLimited(_ providerID: String, retryAfter: TimeInterval?, now: Date) {
        let strikes = (entries[providerID]?.strikes ?? 0) + 1
        let delay = Self.delay(retryAfter: retryAfter, strikes: strikes)
        entries[providerID] = Entry(strikes: strikes, until: now.addingTimeInterval(delay))
    }

    mutating func recordSuccess(_ providerID: String) {
        entries[providerID] = nil
    }

    static func delay(retryAfter: TimeInterval?, strikes: Int) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return min(max(retryAfter, minDelay), maxDelay)
        }
        let exponent = Double(max(strikes, 1) - 1)
        return min(baseDelay * pow(2, exponent), maxDelay)
    }

    /// `Retry-After` は秒数か HTTP 日付。0 以下や読めない値は nil。
    static func retryAfter(header: String?, now: Date) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return seconds > 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        let seconds = date.timeIntervalSince(now)
        return seconds > 0 ? seconds : nil
    }
}
