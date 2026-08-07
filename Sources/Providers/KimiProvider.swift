import Foundation

enum KimiProvider {
    private static let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    static func fetch() async -> QuotaSnapshot {
        do {
            var creds = try loadCredentials()
            if isExpired(creds), let refresh = creds.refreshToken, !refresh.isEmpty {
                if let refreshed = try? await refreshAccessToken(refresh) {
                    creds.accessToken = refreshed.access
                    if let r = refreshed.refresh { creds.refreshToken = r }
                    if let exp = refreshed.expiresAt { creds.expiresAt = exp }
                    try? saveCredentials(creds)
                }
            }

            guard let access = creds.accessToken, !access.isEmpty else {
                return .failed(.kimi, message: "未登录 Kimi Code，请运行 kimi login")
            }

            var (data, response) = try await HTTP.get(
                usagesURL,
                headers: [
                    "Authorization": "Bearer \(access)",
                    "Accept": "application/json"
                ]
            )

            if response.statusCode == 401, let refresh = creds.refreshToken, !refresh.isEmpty {
                let refreshed = try await refreshAccessToken(refresh)
                creds.accessToken = refreshed.access
                if let r = refreshed.refresh { creds.refreshToken = r }
                if let exp = refreshed.expiresAt { creds.expiresAt = exp }
                try? saveCredentials(creds)
                (data, response) = try await HTTP.get(
                    usagesURL,
                    headers: [
                        "Authorization": "Bearer \(refreshed.access)",
                        "Accept": "application/json"
                    ]
                )
            }

            guard (200..<300).contains(response.statusCode),
                  let json = HTTP.jsonObject(data) else {
                return .failed(.kimi, message: "Kimi 用量接口失败 (\(response.statusCode))")
            }

            return mapUsage(json)
        } catch {
            return .failed(.kimi, message: error.localizedDescription)
        }
    }

    private struct Credentials: Codable {
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: String?
        var expiresIn: Int?
        var tokenType: String?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case scope
        }
    }

    private static func credentialsPath() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["KIMI_CODE_CREDENTIALS"]
            ?? ProcessInfo.processInfo.environment["KIMI_CREDENTIALS"],
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        if let home = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("credentials/kimi-code.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
    }

    private static func loadCredentials() throws -> Credentials {
        let url = credentialsPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "AIQuota", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 Kimi 凭证，请运行 kimi login"
            ])
        }
        return try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: url))
    }

    private static func saveCredentials(_ creds: Credentials) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(creds).write(to: credentialsPath(), options: .atomic)
    }

    private static func isExpired(_ creds: Credentials) -> Bool {
        guard let expiresAt = creds.expiresAt else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: expiresAt)
            ?? ISO8601DateFormatter().date(from: expiresAt)
        guard let date else { return false }
        return date.timeIntervalSinceNow <= 60
    }

    private static func refreshAccessToken(_ refreshToken: String) async throws -> (access: String, refresh: String?, expiresAt: String?) {
        let body =
            "grant_type=refresh_token&refresh_token=\(refreshToken.urlFormEncoded)&client_id=\(clientID.urlFormEncoded)"
        let (data, response) = try await HTTP.post(
            refreshURL,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json"
            ],
            body: Data(body.utf8)
        )
        guard (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data),
              let access = json["access_token"] as? String, !access.isEmpty
        else {
            throw NSError(domain: "AIQuota", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Kimi token 刷新失败，请重新 kimi login"
            ])
        }
        return (access, json["refresh_token"] as? String, json["expires_at"] as? String)
    }

    private static func mapUsage(_ json: [String: Any]) -> QuotaSnapshot {
        var remainings: [Double] = []
        var details: [String] = []

        if let usage = json["usage"] as? [String: Any] {
            if let rem = remainingPercent(from: usage) {
                remainings.append(rem)
                details.append(String(format: "7d %.0f%% left", rem))
            }
        }

        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                let window = limit["window"] as? [String: Any]
                let duration = JSONPath.double(window?["duration"]) ?? 0
                let unit = (window?["timeUnit"] as? String) ?? (window?["time_unit"] as? String) ?? ""
                let detail = (limit["detail"] as? [String: Any]) ?? limit
                guard let rem = remainingPercent(from: detail) else { continue }
                let is5h = duration == 300 && unit.uppercased().contains("MINUTE")
                if is5h {
                    remainings.append(rem)
                    details.append(String(format: "5h %.0f%% left", rem))
                }
            }
        }

        let membership = (json["user"] as? [String: Any])?["membership"] as? [String: Any]
        let level = membership?["level"] as? String
        let plan = planName(level)

        let remaining = remainings.min() ?? 0
        return QuotaSnapshot(
            provider: .kimi,
            remainingPercent: remaining,
            detail: details.isEmpty ? "无用量数据" : details.joined(separator: " · "),
            planName: plan,
            updatedAt: Date(),
            error: nil
        )
    }

    private static func remainingPercent(from row: [String: Any]) -> Double? {
        let limit = JSONPath.double(row["limit"])
        if let remaining = JSONPath.double(row["remaining"]), let limit, limit > 0 {
            return max(0, min(100, remaining / limit * 100))
        }
        if let used = JSONPath.double(row["used"]), let limit, limit > 0 {
            return max(0, min(100, (1 - used / limit) * 100))
        }
        if let remaining = JSONPath.double(row["remaining"]) {
            // Some payloads already use percent-like remaining.
            if remaining <= 100 { return remaining }
        }
        return nil
    }

    private static func planName(_ level: String?) -> String? {
        switch level {
        case "LEVEL_FREE": return "Free"
        case "LEVEL_BASIC": return "Adagio"
        case "LEVEL_STANDARD": return "Moderato"
        case "LEVEL_INTERMEDIATE": return "Allegretto"
        case "LEVEL_ADVANCED": return "Allegro"
        case "LEVEL_PREMIUM": return "Vivace"
        default: return level
        }
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
