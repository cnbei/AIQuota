import Foundation

enum CodexProvider {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch() async -> QuotaSnapshot {
        do {
            var auth = try loadAuth()
            if needsRefresh(auth), let refresh = auth.tokens?.refreshToken, !refresh.isEmpty {
                if let refreshed = try? await refreshTokens(refresh) {
                    applyRefresh(&auth, refreshed)
                    try? saveAuth(auth)
                }
            }

            guard let access = auth.tokens?.accessToken, !access.isEmpty else {
                return .failed(.codex, message: "未登录 Codex，请先运行 codex 登录")
            }

            var (data, response) = try await fetchUsage(accessToken: access, accountID: auth.tokens?.accountID)
            if response.statusCode == 401 || response.statusCode == 403,
               let refresh = auth.tokens?.refreshToken, !refresh.isEmpty {
                let refreshed = try await refreshTokens(refresh)
                applyRefresh(&auth, refreshed)
                try? saveAuth(auth)
                (data, response) = try await fetchUsage(accessToken: refreshed.access, accountID: auth.tokens?.accountID)
            }

            guard (200..<300).contains(response.statusCode),
                  let json = HTTP.jsonObject(data) else {
                return .failed(.codex, message: "Codex 用量接口失败 (\(response.statusCode))")
            }

            return mapUsage(json)
        } catch {
            return .failed(.codex, message: error.localizedDescription)
        }
    }

    // MARK: - Auth file

    private struct AuthFile: Codable {
        var tokens: Tokens?
        var lastRefresh: String?
        var OPENAI_API_KEY: String?

        enum CodingKeys: String, CodingKey {
            case tokens
            case lastRefresh = "last_refresh"
            case OPENAI_API_KEY
        }
    }

    private struct Tokens: Codable {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case accountID = "account_id"
        }
    }

    private static func authPath() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    private static func loadAuth() throws -> AuthFile {
        let url = authPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "AIQuota", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到 ~/.codex/auth.json，请先运行 codex 登录"
            ])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AuthFile.self, from: data)
    }

    private static func saveAuth(_ auth: AuthFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(auth)
        try data.write(to: authPath(), options: .atomic)
    }

    private static func needsRefresh(_ auth: AuthFile) -> Bool {
        guard let token = auth.tokens?.accessToken else { return false }
        if let exp = jwtExp(token) {
            return exp.timeIntervalSinceNow <= 5 * 60
        }
        return false
    }

    private static func jwtExp(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? TimeInterval ?? (obj["exp"] as? Int).map(Double.init)
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func applyRefresh(_ auth: inout AuthFile, _ refreshed: (access: String, refresh: String?, idToken: String?)) {
        var tokens = auth.tokens ?? Tokens()
        tokens.accessToken = refreshed.access
        if let r = refreshed.refresh { tokens.refreshToken = r }
        if let id = refreshed.idToken { tokens.idToken = id }
        auth.tokens = tokens
        auth.lastRefresh = ISO8601DateFormatter().string(from: Date())
    }

    private static func refreshTokens(_ refreshToken: String) async throws -> (access: String, refresh: String?, idToken: String?) {
        let body =
            "grant_type=refresh_token&client_id=\(clientID.urlFormEncoded)&refresh_token=\(refreshToken.urlFormEncoded)"
        let (data, response) = try await HTTP.post(
            refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
        guard (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data),
              let access = json["access_token"] as? String, !access.isEmpty
        else {
            throw NSError(domain: "AIQuota", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Codex token 刷新失败，请重新登录 codex"
            ])
        }
        return (access, json["refresh_token"] as? String, json["id_token"] as? String)
    }

    private static func fetchUsage(accessToken: String, accountID: String?) async throws -> (Data, HTTPURLResponse) {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "AIQuota"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try await HTTP.get(usageURL, headers: headers)
    }

    private static func mapUsage(_ json: [String: Any]) -> QuotaSnapshot {
        let plan = json["plan_type"] as? String
        let rate = json["rate_limit"] as? [String: Any]

        var usedPercents: [Double] = []
        var details: [String] = []

        func consider(_ window: [String: Any]?, label: String) {
            guard let window else { return }
            let seconds = JSONPath.double(window["limit_window_seconds"]) ?? 0
            let used = JSONPath.double(window["used_percent"]) ?? 0
            let name: String
            if seconds <= 6 * 3600 { name = "5h" }
            else if seconds >= 6 * 24 * 3600 { name = "7d" }
            else { name = label }
            usedPercents.append(used)
            details.append(String(format: "%@ %.0f%% used", name, used))
        }

        consider(rate?["primary_window"] as? [String: Any], label: "primary")
        consider(rate?["secondary_window"] as? [String: Any], label: "secondary")

        // Prefer the tighter (higher used) window for the ring.
        let used = usedPercents.max() ?? 0
        let remaining = max(0, min(100, 100 - used))

        return QuotaSnapshot(
            provider: .codex,
            remainingPercent: remaining,
            detail: details.isEmpty ? "无窗口数据" : details.joined(separator: " · "),
            planName: plan,
            updatedAt: Date(),
            error: nil
        )
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
