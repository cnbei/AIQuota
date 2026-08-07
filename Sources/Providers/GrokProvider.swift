import Foundation

/// Grok Build credits from local `~/.grok/auth.json` + cli-chat-proxy billing API.
enum GrokProvider {
    private static let billingURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    )!
    private static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let clientVersion = "0.2.118"

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

            var (data, response) = try await fetchBilling(accessToken: auth.accessToken)
            if response.statusCode == 401 || response.statusCode == 403,
               !auth.refreshToken.isEmpty {
                let refreshed = try await refreshTokens(
                    refreshToken: auth.refreshToken,
                    clientID: auth.clientID
                )
                applyRefresh(&auth, refreshed)
                try? saveAuth(auth)
                (data, response) = try await fetchBilling(accessToken: auth.accessToken)
            }

            guard (200..<300).contains(response.statusCode),
                  let json = HTTP.jsonObject(data) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    return .failed(.grok, message: "Grok 登录已失效，请重新运行 grok login")
                }
                return .failed(.grok, message: "Grok 额度接口失败 (\(response.statusCode))")
            }

            return mapBilling(json, planHint: auth.planHint)
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
        var planHint: String?
    }

    private static func authPath() -> URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
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

    private static func refreshTokens(
        refreshToken: String,
        clientID: String
    ) async throws -> (access: String, refresh: String?) {
        let body =
            "grant_type=refresh_token&client_id=\(clientID.urlFormEncoded)&refresh_token=\(refreshToken.urlFormEncoded)"
        let (data, response) = try await HTTP.post(
            tokenURL,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
                "User-Agent": "grok-cli/\(clientVersion)",
                "x-grok-client-version": clientVersion,
                "x-grok-client-surface": "grok-build",
            ],
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

    private static func fetchBilling(accessToken: String) async throws -> (Data, HTTPURLResponse) {
        try await HTTP.get(
            billingURL,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "User-Agent": "grok-cli/\(clientVersion)",
                "x-grok-client-version": clientVersion,
                "x-grok-client-surface": "grok-build",
                "x-grok-client-mode": "cli",
            ]
        )
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

        // Prefer Grok Build product usage when present.
        var buildUsed: Double?
        if let products = config["productUsage"] as? [[String: Any]] {
            for row in products {
                let product = ((row["product"] as? String) ?? "").lowercased()
                if product.contains("grokbuild") || product.contains("grok_build") || product.contains("build") {
                    buildUsed = JSONPath.double(row["usagePercent"]) ?? JSONPath.double(row["usage_percent"])
                    break
                }
            }
        }

        let creditUsed = JSONPath.double(config["creditUsagePercent"])
            ?? JSONPath.double(config["credit_usage_percent"])
        let usedPercent = buildUsed ?? creditUsed

        guard let usedPercent else {
            return .failed(.grok, message: "无法解析 Grok Build 额度字段")
        }

        let remaining = max(0, min(100, 100 - usedPercent))

        let period = (config["currentPeriod"] as? [String: Any])
            ?? (config["current_period"] as? [String: Any])
        let periodType = ((period?["type"] as? String) ?? "").uppercased()
        let end = JSONPath.string(period?["end"]).flatMap(parseDate)
        let kind: QuotaWindowKind = periodType.contains("MONTH") ? .thirtyDay : .sevenDay

        var detailParts: [String] = [String(format: "Grok Build %.0f%% used", usedPercent)]
        if let creditUsed, buildUsed != nil, abs(creditUsed - usedPercent) > 0.05 {
            detailParts.append(String(format: "Credits %.0f%%", creditUsed))
        }
        if let onDemandUsed = nestedVal(config["onDemandUsed"]) ?? nestedVal(config["on_demand_used"]),
           let onDemandCap = nestedVal(config["onDemandCap"]) ?? nestedVal(config["on_demand_cap"]),
           onDemandCap > 0 {
            detailParts.append(String(format: "On-demand %.0f / %.0f", onDemandUsed, onDemandCap))
        }

        let plan = JSONPath.string(config["subscription_tier"])
            ?? JSONPath.string(config["subscriptionTier"])
            ?? planHint

        return QuotaSnapshot(
            provider: .grok,
            remainingPercent: remaining,
            detail: detailParts.joined(separator: " · "),
            planName: plan,
            windows: [
                QuotaWindow(
                    kind: kind,
                    title: "Grok Build",
                    usedPercent: usedPercent,
                    resetsAt: end
                )
            ],
            updatedAt: Date(),
            error: nil
        )
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
