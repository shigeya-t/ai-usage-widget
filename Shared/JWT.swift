import Foundation

/// JWT の payload を読む共通処理。トークン文字列はログに出さない。
enum JWT {
    static func payload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    static func subject(_ jwt: String) throws -> String {
        guard let json = payload(jwt),
              let sub = json["sub"] as? String,
              !sub.isEmpty
        else {
            throw CursorSessionError.invalidToken
        }
        return sub
    }

    static func expiry(_ jwt: String) -> Date? {
        guard let json = payload(jwt) else { return nil }
        let exp: TimeInterval?
        if let value = json["exp"] as? TimeInterval {
            exp = value
        } else if let value = json["exp"] as? Int {
            exp = TimeInterval(value)
        } else {
            exp = nil
        }
        guard let exp else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func nestedString(_ jwt: String, path: [String]) -> String? {
        guard var current: Any = payload(jwt) else { return nil }
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? String
    }
}
