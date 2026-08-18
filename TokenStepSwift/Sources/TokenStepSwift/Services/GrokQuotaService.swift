import Foundation

enum GrokQuotaService {
    static var authURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".grok/auth.json")

    static func read() throws -> ProviderQuota {
        guard var session = readSession() else {
            throw TokenStepError.message(L("需要 grok login"))
        }
        if QuotaAuth.needsRefresh(session.token), let refresh = session.refreshToken, !refresh.isEmpty {
            if let refreshed = try? refreshTokens(refreshToken: refresh, clientID: session.clientID) {
                applyRefresh(&session, refreshed)
                persistSession(session)
            }
        }

        var windows: [QuotaWindow] = []
        var lastError: Error = TokenStepError.message(L("Grok 额度暂不可用"))
        for url in endpoints {
            do {
                let payload = try fetchJSON(url: url, session: session)
                windows.append(contentsOf: Self.windows(from: payload).filter { candidate in
                    !windows.contains(where: { $0.kind == candidate.kind })
                })
            } catch {
                if let refresh = session.refreshToken, !refresh.isEmpty,
                   let refreshed = try? refreshTokens(refreshToken: refresh, clientID: session.clientID) {
                    applyRefresh(&session, refreshed)
                    persistSession(session)
                    if let payload = try? fetchJSON(url: url, session: session) {
                        windows.append(contentsOf: Self.windows(from: payload).filter { candidate in
                            !windows.contains(where: { $0.kind == candidate.kind })
                        })
                        continue
                    }
                }
                lastError = TokenStepError.message(L("Grok 额度暂不可用"))
            }
        }
        if !windows.isEmpty {
            let weekly = windows.first(where: { $0.kind == .weekly })?.usedPercent
            return ProviderQuota(
                provider: .grok,
                windows: windows,
                status: .available,
                fetchedAt: Date(),
                message: nil,
                detail: windows
                    .prefix(1)
                    .map { String(format: "%@ %.0f%% used", $0.displayTitle, $0.usedPercent) }
                    .joined(separator: " · "),
                metrics: QuotaMetrics(grokWeeklyUsed: weekly)
            )
        }
        throw lastError
    }

    static func productWindows(from config: [String: Any], kind: QuotaWindowKind, reset: Date?) -> [QuotaWindow] {
        let rows = (config["productUsage"] as? [[String: Any]])
            ?? (config["product_usage"] as? [[String: Any]])
            ?? []
        var seen: [String: Double] = [:]
        for row in rows {
            let title = grokProductTitle(row["product"] ?? row["productId"] ?? row["id"])
            let used = QuotaJSON.number(row["usagePercent"] ?? row["usage_percent"])
                ?? nestedProductVal(row["usagePercent"])
            guard let used else { continue }
            seen[title] = max(seen[title] ?? 0, min(max(used, 0), 100))
        }
        return seen
            .map { title, used in
                QuotaWindow(
                    kind: kind,
                    usedPercent: used,
                    remaining: 100 - used,
                    total: 100,
                    resetsAt: reset,
                    title: title
                )
            }
            .sorted { $0.usedPercent > $1.usedPercent }
    }

    private static func grokProductTitle(_ raw: Any?) -> String {
        if let number = raw as? Int {
            return grokProductTitle(id: number)
        }
        if let number = raw as? NSNumber {
            return grokProductTitle(id: number.intValue)
        }
        let text = ((raw as? String) ?? "").lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let id = Int(text) {
            return grokProductTitle(id: id)
        }
        if text.contains("imagine") || text.contains("image") || text.contains("video") { return "Imagine" }
        if text.contains("build") { return "Grok Build" }
        if text.contains("chat") { return "Chat" }
        if text.contains("voice") { return "Voice" }
        if text.contains("bot") { return "Grok Bot" }
        if text == "api" || text.contains("productapi") { return "API" }
        return L("其他")
    }

    private static func grokProductTitle(id: Int) -> String {
        switch id {
        case 1: return "API"
        case 2: return "Grok Build"
        case 3: return "Plugins"
        case 4: return "Chat"
        case 5: return "Imagine"
        case 6: return "Voice"
        case 7: return "Grok Bot"
        default: return L("其他")
        }
    }

    private static func nestedProductVal(_ value: Any?) -> Double? {
        if let number = QuotaJSON.number(value) { return number }
        if let object = value as? [String: Any] {
            return QuotaJSON.number(object["val"] ?? object["value"])
        }
        return nil
    }

    static func hasLocalSession() -> Bool {
        readSession() != nil
    }

    static func windows(from payload: Any) -> [QuotaWindow] {
        let object = (payload as? [String: Any]) ?? [:]
        let config = (object["config"] as? [String: Any]) ?? object
        var windows: [QuotaWindow] = []

        if let used = QuotaJSON.number(config["creditUsagePercent"] ?? object["creditUsagePercent"]) {
            let period = config["currentPeriod"] as? [String: Any]
            let kind: QuotaWindowKind
            if let type = period?["type"] as? String, type.uppercased().contains("WEEK") {
                kind = .weekly
            } else {
                kind = .monthlyCredits
            }
            let reset = date(from: period?["end"] ?? config["billingPeriodEnd"] ?? object["billingPeriodEnd"])
            let usedPercent = min(max(used, 0), 100)
            windows.append(
                QuotaWindow(
                    kind: kind,
                    usedPercent: usedPercent,
                    remaining: 100 - usedPercent,
                    total: 100,
                    resetsAt: reset,
                    title: kind == .weekly ? L("本周共用") : nil
                )
            )
        }

        if let used = cent(config["used"] ?? object["used"]),
           let total = cent(config["monthlyLimit"] ?? object["monthlyLimit"] ?? object["limit"]),
           total > 0,
           let usedPercent = QuotaJSON.percent(used: used, remaining: nil, total: total) {
            let reset = date(from: config["billingPeriodEnd"] ?? object["billingPeriodEnd"])
            if !windows.contains(where: { $0.kind == .monthlyCredits }) {
                windows.append(
                    QuotaWindow(kind: .monthlyCredits, usedPercent: usedPercent, remaining: max(total - used, 0), total: total, resetsAt: reset)
                )
            }
        }

        if windows.isEmpty,
           let window = window(from: config["credits"] ?? object["credits"] ?? config["credit"] ?? object["credit"], kind: .monthlyCredits) {
            windows.append(window)
        }
        return windows
    }

    static func sessionToken(from object: [String: Any]) -> String? {
        session(from: object)?.token
    }

    static func looksLikeSessionToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("xai-") { return false }
        if trimmed.hasPrefix("eyJ") { return true }
        return trimmed.count >= 40
    }

    private static func fetchJSON(url: URL, session: GrokSession) throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        for (header, value) in grokHeaders(session: session) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return try HTTPJSONClient.jsonObject(for: request)
    }

    private static func grokHeaders(session: GrokSession? = nil, includeAuth: Bool = true) -> [String: String] {
        let version = clientVersion()
        var headers = [
            "Accept": "application/json",
            "User-Agent": "grok-cli/\(version)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "x-grok-client-version": version,
            "x-grok-client-identifier": "grok-shell",
            "x-grok-client-surface": "grok-build",
            "x-grok-client-mode": "cli"
        ]
        if includeAuth, let session {
            headers["Authorization"] = "Bearer \(session.token)"
            if let userId = session.userId, !userId.isEmpty {
                headers["x-userid"] = userId
            }
        }
        return headers
    }

    private static func clientVersion() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/version.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty
        else {
            return "1.0.4"
        }
        return version
    }

    private static func refreshTokens(refreshToken: String, clientID: String?) throws -> (access: String, refresh: String?) {
        guard let url = URL(string: "https://auth.x.ai/oauth2/token") else {
            throw TokenStepError.message(L("需要 grok login"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let clientID, !clientID.isEmpty {
            fields["client_id"] = clientID
        }
        request.httpBody = QuotaAuth.formEncoded(fields)
        let (data, http) = try HTTPJSONClient.exchange(request)
        guard (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty
        else {
            throw TokenStepError.message(L("需要 grok login"))
        }
        return (access, json["refresh_token"] as? String)
    }

    private static func applyRefresh(_ session: inout GrokSession, _ refreshed: (access: String, refresh: String?)) {
        session.token = refreshed.access
        if let refresh = refreshed.refresh, !refresh.isEmpty {
            session.refreshToken = refresh
        }
    }

    private static func persistSession(_ session: GrokSession) {
        guard var root = readAuthObject(), let fileKey = session.fileKey,
              var entry = root[fileKey] as? [String: Any]
        else { return }
        entry["key"] = session.token
        if let refresh = session.refreshToken, !refresh.isEmpty {
            entry["refresh_token"] = refresh
        }
        if let exp = QuotaAuth.jwtExp(session.token) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            entry["expires_at"] = formatter.string(from: exp)
        }
        root[fileKey] = entry
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: authURL, options: .atomic)
    }

    private static func window(from value: Any?, kind: QuotaWindowKind) -> QuotaWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used = QuotaJSON.number(object["used"] ?? object["used_percent"]) ?? cent(object["used"])
        let remaining = QuotaJSON.number(object["remaining"] ?? object["remain"] ?? object["balance"])
        let total = QuotaJSON.number(object["total"] ?? object["limit"] ?? object["quota"]) ?? cent(object["monthlyLimit"])
        guard let usedPercent = QuotaJSON.percent(used: used, remaining: remaining, total: total) else {
            return nil
        }
        return QuotaWindow(kind: kind, usedPercent: usedPercent, remaining: remaining, total: total, resetsAt: nil)
    }

    private static func readSession() -> GrokSession? {
        if let stored = TokenStepSecrets.get(.grokAccessToken), looksLikeSessionToken(stored) {
            return GrokSession(
                token: stored,
                userId: readAuthObject().flatMap(userId(from:)),
                refreshToken: nil,
                clientID: nil,
                fileKey: nil
            )
        }
        guard let object = readAuthObject(), !isPlainXAIKey(object) else { return nil }
        return session(from: object)
    }

    private static func readAuthObject() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func session(from object: [String: Any]) -> GrokSession? {
        let preferred = object
            .compactMap { key, value -> (String, [String: Any])? in
                guard let entry = value as? [String: Any] else { return nil }
                return (key, entry)
            }
            .sorted { lhs, rhs in
                let leftOIDC = (lhs.1["auth_mode"] as? String) == "oidc"
                let rightOIDC = (rhs.1["auth_mode"] as? String) == "oidc"
                if leftOIDC != rightOIDC { return leftOIDC && !rightOIDC }
                return lhs.0 < rhs.0
            }
            .first

        if let (fileKey, entry) = preferred, let token = token(in: entry) {
            let clientID = (entry["oidc_client_id"] as? String)
                ?? fileKey.split(separator: ":").last.map(String.init)
            return GrokSession(
                token: token,
                userId: userId(from: entry) ?? userId(from: object),
                refreshToken: entry["refresh_token"] as? String,
                clientID: clientID,
                fileKey: fileKey
            )
        }
        if let token = token(in: object) {
            return GrokSession(
                token: token,
                userId: userId(from: object),
                refreshToken: object["refresh_token"] as? String,
                clientID: object["oidc_client_id"] as? String,
                fileKey: nil
            )
        }
        return nil
    }

    private static func userId(from object: [String: Any]) -> String? {
        let keys = ["user_id", "userId", "principal_id", "principalId"]
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let userId = userId(from: nested) {
                return userId
            }
        }
        return nil
    }

    private static func isPlainXAIKey(_ object: [String: Any]) -> Bool {
        let values = [object["api_key"], object["apiKey"], object["key"]].compactMap { $0 as? String }
        return values.contains { $0.hasPrefix("xai-") } && token(in: object) == nil
    }

    private static func token(in object: [String: Any]) -> String? {
        let keys = ["access_token", "accessToken", "sessionToken", "token", "key"]
        for key in keys {
            if let value = object[key] as? String, looksLikeSessionToken(value) {
                return value
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let token = token(in: nested) {
                return token
            }
        }
        return nil
    }

    private static func cent(_ value: Any?) -> Double? {
        if let number = QuotaJSON.number(value) { return number }
        if let object = value as? [String: Any] {
            return QuotaJSON.number(object["val"] ?? object["value"])
        }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.grok.date(from: text) {
            return date
        }
        return ISO8601DateFormatter.grokNoFraction.date(from: text)
    }

    private static var endpoints: [URL] {
        [
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            "https://cli-chat-proxy.grok.com/v1/billing"
        ].compactMap(URL.init(string:))
    }
}

private struct GrokSession {
    var token: String
    var userId: String?
    var refreshToken: String?
    var clientID: String?
    var fileKey: String?
}

private extension ISO8601DateFormatter {
    static let grok: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let grokNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
