import Foundation

enum QuotaAuth {
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload += "="
        }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jwtExp(_ token: String) -> Date? {
        guard let payload = jwtPayload(token) else { return nil }
        if let exp = payload["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    static func needsRefresh(_ token: String, leeway: TimeInterval = 300) -> Bool {
        guard let exp = jwtExp(token) else { return false }
        return exp.timeIntervalSinceNow <= leeway
    }

    static func cursorUserId(fromJWT token: String) -> String? {
        guard let sub = jwtPayload(token)?["sub"] as? String, !sub.isEmpty else { return nil }
        let parts = sub.split(separator: "|", omittingEmptySubsequences: false)
        let userId = String(parts.count > 1 ? parts[1] : parts[0])
        return userId.isEmpty ? nil : userId
    }

    static func formEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed
        let body = fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    static func date(from value: Any?) -> Date? {
        if let text = value as? String, !text.isEmpty {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) {
                return date
            }
            if let dot = text.firstIndex(of: "."),
               let end = text.lastIndex(of: "Z") ?? text.lastIndex(of: "+"),
               end > dot {
                let fraction = text[text.index(after: dot)..<end]
                let trimmed = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                let normalized = String(text[..<text.index(after: dot)]) + trimmed + String(text[end...])
                if let date = fractional.date(from: normalized) ?? plain.date(from: normalized) {
                    return date
                }
            }
        }
        if let seconds = QuotaJSON.number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        return nil
    }
}
