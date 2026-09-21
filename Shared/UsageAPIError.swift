import Foundation

enum UsageAPIError: LocalizedError {
    case unauthorized
    case httpStatus(Int)
    case decodeFailed
    case rateLimited
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
}

typealias CursorAPIError = UsageAPIError
