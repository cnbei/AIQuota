import Foundation

enum KimiQuotaService {
    static var homeURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi")

    static func read() throws -> ProviderQuota {
        guard let token = readWebOrOAuthToken() else {
            throw TokenStepError.message(L("未登录 Kimi"))
        }
        if let membership = try? readMembership(token: token), membership.isAvailable {
            return membership
        }
        if let recovered = recoverAfterUnauthorized(current: token) {
            return recovered
        }
        var lastError: Error = TokenStepError.message(L("Kimi 额度暂不可用"))
        for url in codingEndpoints {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 6
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let object = try HTTPJSONClient.jsonObject(for: request)
                let parsed = windows(from: object)
                if !parsed.isEmpty {
                    return ProviderQuota(
                        provider: .kimi,
                        windows: parsed,
                        status: .available,
                        fetchedAt: Date(),
                        message: nil,
                        metrics: QuotaMetrics(
                            kimiMembershipUsed: parsed.first(where: { $0.kind == .monthlyCredits })?.usedPercent,
                            kimiCodeUsed: parsed.filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }.map(\.usedPercent).max()
                        )
                    )
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func recoverAfterUnauthorized(current: String) -> ProviderQuota? {
        KimiWebAuth.clearStoredToken()
        guard let fresh = KimiWebAuth.importFreshFromBrowsers(), fresh != current else {
            return nil
        }
        guard let quota = try? readMembership(token: fresh), quota.isAvailable else {
            return nil
        }
        return quota
    }

    static func windows(from payload: Any) -> [QuotaWindow] {
        if let membership = membershipWindows(from: payload), !membership.isEmpty {
            return membership
        }
        let object = (payload as? [String: Any]) ?? [:]
        let data = (object["data"] as? [String: Any]) ?? object
        var result: [QuotaWindow] = []
        if let session = window(from: data["session"] ?? data["session_usage"], kind: .session) {
            result.append(session)
        }
        if let weekly = window(from: data["weekly"] ?? data["week"] ?? data["weekly_usage"], kind: .weekly) {
            result.append(weekly)
        }
        if result.isEmpty, let fallback = window(from: data, kind: .weekly) {
            result.append(fallback)
        }
        return result
    }

    static func membershipWindows(from payload: Any) -> [QuotaWindow]? {
        let object = (payload as? [String: Any]) ?? [:]
        let balance = (object["subscriptionBalance"] as? [String: Any])
            ?? (object["subscription_balance"] as? [String: Any])
        guard let balance else { return nil }

        var result: [QuotaWindow] = []
        if let ratio = QuotaJSON.number(balance["amountUsedRatio"] ?? balance["amount_used_ratio"]) {
            let used = ratio <= 1.0001 ? ratio * 100 : ratio
            result.append(
                QuotaWindow(
                    kind: .monthlyCredits,
                    usedPercent: min(max(used, 0), 100),
                    remaining: min(max(100 - used, 0), 100),
                    total: 100,
                    resetsAt: QuotaAuth.date(from: balance["expireTime"] ?? balance["expire_time"]),
                    title: "总使用量"
                )
            )
        }

        func appendCodeLimit(keys: [String], kind: QuotaWindowKind) {
            for key in keys {
                guard let row = object[key] as? [String: Any] else { continue }
                let ratio = QuotaJSON.number(row["ratio"])
                let used: Double?
                if let ratio {
                    used = ratio <= 1.0001 ? ratio * 100 : ratio
                } else if row["enabled"] as? Bool == true {
                    used = 0
                } else {
                    used = nil
                }
                guard let used else { continue }
                result.append(
                    QuotaWindow(
                        kind: kind,
                        usedPercent: min(max(used, 0), 100),
                        remaining: min(max(100 - used, 0), 100),
                        total: 100,
                        resetsAt: QuotaAuth.date(from: row["resetTime"] ?? row["reset_time"] ?? row["expireTime"]),
                        title: "Code"
                    )
                )
                return
            }
        }

        appendCodeLimit(keys: ["ratelimitCode5h", "ratelimit_code_5h", "rateLimitCode5h"], kind: .fiveHour)
        appendCodeLimit(keys: ["ratelimitCode7d", "ratelimit_code_7d", "rateLimitCode7d"], kind: .sevenDay)
        return result.isEmpty ? nil : result
    }

    private static func readMembership(token: String) throws -> ProviderQuota {
        guard let url = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats") else {
            throw TokenStepError.message(L("Kimi 额度暂不可用"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpBody = Data("{}".utf8)
        for (header, value) in membershipHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let object = try HTTPJSONClient.jsonObject(for: request)
        var parsed = membershipWindows(from: object) ?? []
        if let coding = try? fetchCodingWindows(token: token) {
            parsed = merge(parsed, with: coding)
        }
        guard !parsed.isEmpty else {
            throw TokenStepError.message(L("Kimi 额度暂不可用"))
        }
        let membershipUsed = parsed.first(where: { $0.kind == .monthlyCredits })?.usedPercent
        let codeUsed = parsed
            .filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }
            .map(\.usedPercent)
            .max()
        let metrics = QuotaMetrics(kimiMembershipUsed: membershipUsed, kimiCodeUsed: codeUsed)
        return ProviderQuota(
            provider: .kimi,
            windows: parsed,
            status: .available,
            fetchedAt: Date(),
            message: nil,
            detail: QuotaPresentation.detail(
                ProviderQuota(provider: .kimi, windows: parsed, status: .available, metrics: metrics),
                cursorMode: .included,
                kimiMode: .membership
            ),
            metrics: metrics
        )
    }

    private static func fetchCodingWindows(token: String) throws -> [QuotaWindow] {
        guard let url = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        for (header, value) in membershipHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        guard let object = try HTTPJSONClient.jsonObject(for: request) as? [String: Any],
              let usages = object["usages"] as? [[String: Any]],
              let coding = usages.first(where: { ($0["scope"] as? String) == "FEATURE_CODING" })
        else {
            return []
        }

        var result: [QuotaWindow] = []
        if let detail = coding["detail"] as? [String: Any],
           let used = usedPercent(from: detail) {
            result.append(
                QuotaWindow(
                    kind: .sevenDay,
                    usedPercent: used,
                    remaining: 100 - used,
                    total: 100,
                    resetsAt: QuotaAuth.date(from: detail["resetTime"] ?? detail["reset_time"]),
                    title: "Code"
                )
            )
        }
        if let limits = coding["limits"] as? [[String: Any]] {
            for limit in limits {
                let window = limit["window"] as? [String: Any]
                let duration = QuotaJSON.number(window?["duration"]) ?? 0
                let unit = ((window?["timeUnit"] as? String) ?? (window?["time_unit"] as? String) ?? "").uppercased()
                let detail = (limit["detail"] as? [String: Any]) ?? [:]
                guard let used = usedPercent(from: detail) else { continue }
                if duration == 300 && unit.contains("MINUTE") {
                    result.append(
                        QuotaWindow(
                            kind: .fiveHour,
                            usedPercent: used,
                            remaining: 100 - used,
                            total: 100,
                            resetsAt: QuotaAuth.date(from: detail["resetTime"] ?? detail["reset_time"]),
                            title: "Code"
                        )
                    )
                }
            }
        }
        return result
    }

    private static func usedPercent(from detail: [String: Any]) -> Double? {
        let limit = QuotaJSON.number(detail["limit"])
        if let used = QuotaJSON.number(detail["used"]), let limit, limit > 0 {
            return min(max(used / limit * 100, 0), 100)
        }
        if let remaining = QuotaJSON.number(detail["remaining"]), let limit, limit > 0 {
            return min(max((1 - remaining / limit) * 100, 0), 100)
        }
        // GetUsages omits used/remaining at the start of a fresh window.
        if let limit, limit > 0 {
            return 0
        }
        return nil
    }

    private static func merge(_ base: [QuotaWindow], with extra: [QuotaWindow]) -> [QuotaWindow] {
        var result = base
        for window in extra {
            if let index = result.firstIndex(where: { $0.kind == window.kind }) {
                var merged = result[index]
                if merged.resetsAt == nil {
                    merged.resetsAt = window.resetsAt
                }
                result[index] = merged
            } else {
                result.append(window)
            }
        }
        return result
    }

    private static func membershipHeaders(token: String) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "*/*",
            "Authorization": "Bearer \(token)",
            "Cookie": "kimi-auth=\(token)",
            "Origin": "https://www.kimi.com",
            "Referer": "https://www.kimi.com/membership/subscription?tab=quota",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            "connect-protocol-version": "1",
            "x-language": "zh-CN",
            "x-msh-platform": "web",
            "r-timezone": TimeZone.current.identifier
        ]
        if let session = QuotaAuth.jwtPayload(token) {
            if let deviceId = session["device_id"] as? String {
                headers["x-msh-device-id"] = deviceId
            }
            if let sessionId = session["ssid"] as? String {
                headers["x-msh-session-id"] = sessionId
            }
            if let trafficId = session["sub"] as? String {
                headers["x-traffic-id"] = trafficId
            }
        }
        return headers
    }

    private static func window(from value: Any?, kind: QuotaWindowKind) -> QuotaWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let used = QuotaJSON.number(object["used"] ?? object["used_percent"] ?? object["utilization"])
        let remaining = QuotaJSON.number(object["remaining"] ?? object["remain"])
        let total = QuotaJSON.number(object["total"] ?? object["limit"] ?? object["quota"])
        guard let usedPercent = QuotaJSON.percent(used: used, remaining: remaining, total: total) else {
            return nil
        }
        return QuotaWindow(kind: kind, usedPercent: usedPercent, remaining: remaining, total: total, resetsAt: nil)
    }

    private static func readWebOrOAuthToken() -> String? {
        if let token = KimiWebAuth.resolveToken() {
            return token
        }
        let candidates = [
            homeURL.appendingPathComponent("auth.json"),
            homeURL.appendingPathComponent("credentials.json"),
            homeURL.appendingPathComponent("oauth.json"),
            homeURL.appendingPathComponent("config.json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let token = firstToken(in: object), KimiWebAuth.isFresh(token) {
                return token
            }
        }
        return nil
    }

    private static func firstToken(in object: [String: Any]) -> String? {
        let keys = ["access_token", "accessToken", "token", "oauth_token"]
        for key in keys {
            if let value = object[key] as? String, looksLikeSession(value) {
                return value
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let token = firstToken(in: nested) {
                return token
            }
        }
        return nil
    }

    private static func looksLikeSession(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("sk-") { return false }
        return trimmed.split(separator: ".").count == 3 || trimmed.count >= 40
    }

    private static var codingEndpoints: [URL] {
        [
            "https://api.kimi.com/coding/usage",
            "https://www.kimi.com/api/coding/usage"
        ].compactMap(URL.init(string:))
    }
}
