import Foundation

/// Grok Build credits from local `~/.grok/auth.json` + cli-chat-proxy billing API.
enum GrokProvider {
    private static let billingURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    )!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let fallbackClientVersion = "1.0.4"

    static func fetch() async -> QuotaSnapshot {
        do {
            guard var auth = try loadAuth() else {
                return .failed(.grok, message: "未找到 ~/.grok/auth.json，请先运行 grok login")
            }

            if needsRefresh(auth.accessToken), !auth.refreshToken.isEmpty {
                if let refreshed = try? await refreshTokens(
                    refreshToken: auth.refreshToken,
                    clientID: auth.clientID
                ) {
                    applyRefresh(&auth, refreshed)
                    try? saveAuth(auth)
                }
            }

            guard !auth.accessToken.isEmpty else {
                return .failed(.grok, message: "未登录 Grok，请先运行 grok login")
            }

            var (data, response) = try await fetchBilling(accessToken: auth.accessToken, userID: auth.userID)
            if response.statusCode == 401 || response.statusCode == 403,
               !auth.refreshToken.isEmpty {
                let refreshed = try await refreshTokens(
                    refreshToken: auth.refreshToken,
                    clientID: auth.clientID
                )
                applyRefresh(&auth, refreshed)
                try? saveAuth(auth)
                (data, response) = try await fetchBilling(accessToken: auth.accessToken, userID: auth.userID)
            }

            guard (200..<300).contains(response.statusCode),
                  let json = HTTP.jsonObject(data) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    return .failed(.grok, message: "Grok 登录已失效，请重新运行 grok login")
                }
                return .failed(.grok, message: "Grok 额度接口失败 (\(response.statusCode))")
            }

            let plan = await fetchPlanName(accessToken: auth.accessToken) ?? auth.planHint
            return mapBilling(json, planHint: plan)
        } catch {
            return .failed(.grok, message: error.localizedDescription)
        }
    }

    // MARK: - Auth

    private struct AuthState {
        var fileKey: String
        var root: [String: Any]
        var entry: [String: Any]
        var accessToken: String
        var refreshToken: String
        var clientID: String
        var userID: String
        var planHint: String?
    }

    private static func authPath() -> URL {
        grokHome().appendingPathComponent("auth.json")
    }

    private static func loadAuth() throws -> AuthState? {
        let url = authPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Prefer OIDC entries keyed by issuer::client_id.
        let preferred = root
            .compactMap { key, value -> (String, [String: Any])? in
                guard let entry = value as? [String: Any],
                      let token = entry["key"] as? String, !token.isEmpty
                else { return nil }
                return (key, entry)
            }
            .sorted { a, b in
                let aOIDC = (a.1["auth_mode"] as? String) == "oidc"
                let bOIDC = (b.1["auth_mode"] as? String) == "oidc"
                if aOIDC != bOIDC { return aOIDC && !bOIDC }
                return a.0 < b.0
            }
            .first

        guard let (fileKey, entry) = preferred,
              let access = entry["key"] as? String, !access.isEmpty
        else { return nil }

        let clientID = (entry["oidc_client_id"] as? String)
            ?? fileKey.split(separator: ":").last.map(String.init)
            ?? ""
        let refresh = (entry["refresh_token"] as? String) ?? ""
        let userID = (entry["user_id"] as? String)
            ?? (jwtPayload(access)?["sub"] as? String)
            ?? ""
        let tier = jwtPayload(access)?["tier"]
        let planHint: String?
        if let tierInt = tier as? Int {
            planHint = "Tier \(tierInt)"
        } else if let tierStr = tier as? String, !tierStr.isEmpty {
            planHint = tierStr
        } else {
            planHint = nil
        }

        return AuthState(
            fileKey: fileKey,
            root: root,
            entry: entry,
            accessToken: access,
            refreshToken: refresh,
            clientID: clientID,
            userID: userID,
            planHint: planHint
        )
    }

    private static func saveAuth(_ auth: AuthState) throws {
        var root = auth.root
        root[auth.fileKey] = auth.entry
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authPath(), options: .atomic)
    }

    private static func needsRefresh(_ token: String) -> Bool {
        guard let exp = jwtExp(token) else { return false }
        return exp.timeIntervalSinceNow <= 5 * 60
    }

    private static func applyRefresh(
        _ auth: inout AuthState,
        _ refreshed: (access: String, refresh: String?)
    ) {
        auth.accessToken = refreshed.access
        auth.entry["key"] = refreshed.access
        if let refresh = refreshed.refresh, !refresh.isEmpty {
            auth.refreshToken = refresh
            auth.entry["refresh_token"] = refresh
        }
        if let exp = jwtExp(refreshed.access) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            auth.entry["expires_at"] = formatter.string(from: exp)
        }
        if let tier = jwtPayload(refreshed.access)?["tier"] as? Int {
            auth.planHint = "Tier \(tier)"
        }
    }

    private static func grokHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    private static func clientVersion() -> String {
        let url = grokHome().appendingPathComponent("version.json")
        guard let data = try? Data(contentsOf: url),
              let json = HTTP.jsonObject(data),
              let version = json["version"] as? String,
              !version.isEmpty
        else { return fallbackClientVersion }
        return version
    }

    private static func proxyHeaders(accessToken: String? = nil, userID: String? = nil) -> [String: String] {
        let version = clientVersion()
        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": "grok-cli/\(version)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "x-grok-client-version": version,
            "x-grok-client-identifier": "grok-shell",
            "x-grok-client-surface": "grok-build",
            "x-grok-client-mode": "cli",
        ]
        if let accessToken, !accessToken.isEmpty {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        if let userID, !userID.isEmpty {
            headers["x-userid"] = userID
        }
        return headers
    }

    private static func refreshTokens(
        refreshToken: String,
        clientID: String
    ) async throws -> (access: String, refresh: String?) {
        let body =
            "grant_type=refresh_token&client_id=\(clientID.urlFormEncoded)&refresh_token=\(refreshToken.urlFormEncoded)"
        var headers = proxyHeaders()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let (data, response) = try await HTTP.post(
            tokenURL,
            headers: headers,
            body: Data(body.utf8)
        )
        guard (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data),
              let access = json["access_token"] as? String, !access.isEmpty
        else {
            throw NSError(domain: "AIQuota", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Grok token 刷新失败，请重新运行 grok login"
            ])
        }
        return (access, json["refresh_token"] as? String)
    }

    private static func fetchBilling(accessToken: String, userID: String) async throws -> (Data, HTTPURLResponse) {
        try await HTTP.get(billingURL, headers: proxyHeaders(accessToken: accessToken, userID: userID))
    }

    private static func fetchPlanName(accessToken: String) async -> String? {
        guard let (data, response) = try? await HTTP.get(
            settingsURL,
            headers: proxyHeaders(accessToken: accessToken),
            timeout: 2
        ), (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data)
        else { return nil }
        return JSONPath.string(json["subscription_tier_display"])
            ?? JSONPath.string(json["subscriptionTierDisplay"])
            ?? JSONPath.string(json["subscription_tier"])
            ?? JSONPath.string(json["subscriptionTier"])
    }

    private static func jwtExp(_ token: String) -> Date? {
        guard let payload = jwtPayload(token) else { return nil }
        if let exp = payload["exp"] as? TimeInterval {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Mapping

    private static func mapBilling(_ json: [String: Any], planHint: String?) -> QuotaSnapshot {
        let config = (json["config"] as? [String: Any]) ?? json
        let products = parseProductUsage(config["productUsage"] ?? config["product_usage"])

        let creditUsed = JSONPath.double(config["creditUsagePercent"])
            ?? JSONPath.double(config["credit_usage_percent"])

        let onDemandUsed = nestedVal(config["onDemandUsed"]) ?? nestedVal(config["on_demand_used"])
        let onDemandCap = nestedVal(config["onDemandCap"]) ?? nestedVal(config["on_demand_cap"])
        let onDemandPercent: Double? = {
            guard let used = onDemandUsed, let cap = onDemandCap, cap > 0 else { return nil }
            return min(100, max(0, used / cap * 100))
        }()

        let monthlyLimit = nestedVal(config["monthlyLimit"]) ?? nestedVal(config["monthly_limit"])
        let monthlyUsed = nestedVal(config["used"])
        let monthlyPercent: Double? = {
            guard let used = monthlyUsed, let limit = monthlyLimit, limit > 0 else { return nil }
            return min(100, max(0, used / limit * 100))
        }()

        let period = (config["currentPeriod"] as? [String: Any])
            ?? (config["current_period"] as? [String: Any])
        let periodEnd = JSONPath.string(period?["end"])
            ?? JSONPath.string(config["billingPeriodEnd"])
            ?? JSONPath.string(config["billing_period_end"])
        // proto3 omits zero scalars: SuperGrok unified billing drops
        // creditUsagePercent at the start of a fresh period (0% used).
        let hasPeriod = period != nil || periodEnd != nil
        let usedPercent = creditUsed
            ?? products.first(where: { $0.kind == .build })?.used
            ?? onDemandPercent
            ?? monthlyPercent
            ?? (hasPeriod ? 0 : nil)

        guard let usedPercent else {
            return .failed(.grok, message: "无法解析 Grok 额度字段")
        }

        let remaining = max(0, min(100, 100 - usedPercent))
        let periodType = ((period?["type"] as? String) ?? "").uppercased()
        let end = periodEnd.flatMap(parseDate)
        let kind: QuotaWindowKind = periodType.contains("MONTH") ? .thirtyDay : .sevenDay

        var windows: [QuotaWindow] = [
            QuotaWindow(kind: kind, title: "本周共用", usedPercent: usedPercent, resetsAt: end)
        ]
        for row in products.sorted(by: { $0.used > $1.used }) {
            windows.append(QuotaWindow(kind: kind, title: row.kind.title, usedPercent: row.used, resetsAt: end))
        }

        var detailParts: [String] = [String(format: "本周共用 %.0f%% used", usedPercent)]
        let highlighted = products.filter { $0.used > 0.05 }.prefix(3)
        for row in highlighted {
            detailParts.append(String(format: "%@ %.0f%%", row.kind.title, row.used))
        }
        if highlighted.isEmpty {
            detailParts.append("生图/视频/聊天同一池")
        }
        if let onDemandUsed, let onDemandCap, onDemandCap > 0 {
            detailParts.append(String(format: "On-demand %.0f / %.0f", onDemandUsed, onDemandCap))
        }

        let plan = JSONPath.string(config["subscription_tier"])
            ?? JSONPath.string(config["subscriptionTier"])
            ?? planHint

        func used(_ kind: GrokProductKind) -> Double? {
            products.first(where: { $0.kind == kind })?.used
        }

        return QuotaSnapshot(
            provider: .grok,
            remainingPercent: remaining,
            detail: detailParts.joined(separator: " · "),
            planName: plan,
            windows: windows,
            updatedAt: Date(),
            error: nil,
            metrics: QuotaMetrics(
                grokWeeklyUsed: usedPercent,
                grokBuildUsed: used(.build),
                grokImagineUsed: used(.imagine),
                grokChatUsed: used(.chat),
                grokVoiceUsed: used(.voice),
                grokApiUsed: used(.api),
                grokBotUsed: used(.bot)
            )
        )
    }

    private struct ProductRow {
        var kind: GrokProductKind
        var used: Double
    }

    private enum GrokProductKind: String {
        case build, imagine, chat, voice, api, plugins, bot, other

        var title: String {
            switch self {
            case .build: return "Grok Build"
            case .imagine: return "Imagine"
            case .chat: return "Chat"
            case .voice: return "Voice"
            case .api: return "API"
            case .plugins: return "Plugins"
            case .bot: return "Grok Bot"
            case .other: return "其他"
            }
        }

        static func parse(_ raw: Any?) -> GrokProductKind {
            if let n = raw as? Int { return parseID(n) }
            if let n = raw as? NSNumber { return parseID(n.intValue) }
            let s = ((raw as? String) ?? "").lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            if let n = Int(s) { return parseID(n) }
            if s.contains("imagine") || s.contains("image") || s.contains("video") { return .imagine }
            if s.contains("build") { return .build }
            if s.contains("chat") { return .chat }
            if s.contains("voice") { return .voice }
            if s.contains("plugin") { return .plugins }
            if s.contains("bot") { return .bot }
            if s == "api" || s.hasSuffix("api") || s.contains("productapi") { return .api }
            return .other
        }

        /// grok.com Settings → Usage proto ids (Grok Quota Display Pro).
        private static func parseID(_ id: Int) -> GrokProductKind {
            switch id {
            case 1: return .api
            case 2: return .build
            case 3: return .plugins
            case 4: return .chat
            case 5: return .imagine
            case 6: return .voice
            case 7: return .bot
            default: return .other
            }
        }
    }

    private static func parseProductUsage(_ any: Any?) -> [ProductRow] {
        guard let rows = any as? [[String: Any]] else { return [] }
        var seen: [GrokProductKind: Double] = [:]
        for row in rows {
            let kind = GrokProductKind.parse(row["product"] ?? row["productId"] ?? row["id"])
            let used = JSONPath.double(row["usagePercent"])
                ?? JSONPath.double(row["usage_percent"])
                ?? nestedVal(row["usagePercent"])
            guard let used else { continue }
            seen[kind] = max(seen[kind] ?? 0, min(100, max(0, used)))
        }
        return seen.map { ProductRow(kind: $0.key, used: $0.value) }
    }

    private static func nestedVal(_ any: Any?) -> Double? {
        if let n = JSONPath.double(any) { return n }
        if let obj = any as? [String: Any] {
            return JSONPath.double(obj["val"]) ?? JSONPath.double(obj["value"])
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: value) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: value) { return d }

        // Trim >3 fractional digits.
        if let dot = value.firstIndex(of: "."),
           let plus = value.lastIndex(of: "+") ?? value.lastIndex(of: "Z"),
           plus > dot {
            let frac = value[value.index(after: dot)..<plus]
            let trimmed = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            let normalized = String(value[..<value.index(after: dot)]) + trimmed + String(value[plus...])
            if let d = isoFrac.date(from: normalized) { return d }
            if let d = iso.date(from: normalized) { return d }
        }
        return nil
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
