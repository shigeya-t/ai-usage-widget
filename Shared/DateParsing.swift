import Foundation

enum DateParsing {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basic: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()

    static func iso8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? basic.date(from: raw)
    }

    static func unixSeconds(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

/// JSON の数値・文字列のどちらでも Double として読む。
struct JSONNumber: Codable, Equatable {
    var value: Double

    init(_ value: Double) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self.value = value
            return
        }
        if let value = try? container.decode(Int.self) {
            self.value = Double(value)
            return
        }
        if let raw = try? container.decode(String.self), let value = Double(raw) {
            self.value = value
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Unix 秒（数値）または ISO8601 文字列。
struct JSONTimestamp: Codable, Equatable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: value)
            return
        }
        if let value = try? container.decode(Int.self) {
            date = Date(timeIntervalSince1970: TimeInterval(value))
            return
        }
        if let raw = try? container.decode(String.self), let parsed = DateParsing.iso8601(raw) {
            date = parsed
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a timestamp")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date.timeIntervalSince1970)
    }
}
