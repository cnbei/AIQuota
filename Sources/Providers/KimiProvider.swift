import Foundation

/// Reads the membership "总使用量" from
/// `https://www.kimi.com/membership/subscription?tab=quota`
/// via `MembershipService/GetSubscriptionStats`.
enum KimiProvider {
    private static let statsURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats"
    )!
    private static let subscriptionURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.order.v1.SubscriptionService/GetSubscription"
    )!
    private static let codingUsagesURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    )!

    static func fetch() async -> QuotaSnapshot {
        guard let token = KimiWebAuth.resolveToken() else {
            return .failed(
                .kimi,
                message: "需要 Kimi 网页登录态（kimi-auth）。请在浏览器登录 kimi.com 后点「导入网页登录」，或手动粘贴 cookie"
            )
        }

        do {
            let (data, response) = try await postMembership(statsURL, token: token)
            guard (200..<300).contains(response.statusCode),
                  let json = HTTP.jsonObject(data) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    KimiWebAuth.clearStoredToken()
                    return .failed(.kimi, message: "kimi-auth 已失效，请重新导入网页登录")
                }
                return .failed(.kimi, message: "会员额度接口失败 (\(response.statusCode))")
            }

            guard var snap = mapSubscriptionStats(json) else {
                return .failed(.kimi, message: "无法解析总使用量字段")
            }

            // Always try GetUsages to fill Code 5h/7d used% (stats omits ratio when 0%).
            if let codingWindows = await fetchCodingWindows(token: token) {
                snap.windows = mergeWindows(snap.windows, with: codingWindows)
            }

            if snap.planName == nil,
               let plan = await fetchPlanName(token: token) {
                snap.planName = plan
            }

            // Refresh Code used% after merging GetUsages windows.
            let codeUsed = snap.windows
                .filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }
                .compactMap(\.usedPercent)
                .max()
            if var metrics = snap.metrics {
                metrics.kimiCodeUsed = codeUsed ?? metrics.kimiCodeUsed
                snap.metrics = metrics
            }

            return snap
        } catch {
            return .failed(.kimi, message: error.localizedDescription)
        }
    }

    /// Prefer existing membership windows; fill missing used% / reset from coding usages.
    private static func mergeWindows(_ base: [QuotaWindow], with extra: [QuotaWindow]) -> [QuotaWindow] {
        var result = base
        for window in extra {
            if let idx = result.firstIndex(where: { $0.kind == window.kind && ($0.title ?? "") == (window.title ?? "") }) {
                var merged = result[idx]
                if merged.usedPercent == nil { merged.usedPercent = window.usedPercent }
                if merged.resetsAt == nil { merged.resetsAt = window.resetsAt }
                result[idx] = merged
            } else if let idx = result.firstIndex(where: { $0.kind == window.kind }) {
                var merged = result[idx]
                if merged.usedPercent == nil { merged.usedPercent = window.usedPercent }
                if merged.resetsAt == nil { merged.resetsAt = window.resetsAt }
                if merged.title == nil { merged.title = window.title }
                result[idx] = merged
            } else {
                result.append(window)
            }
        }
        return result.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    private static func fetchCodingWindows(token: String) async -> [QuotaWindow]? {
        var requestBody = Data()
        if let data = try? JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]]) {
            requestBody = data
        }
        guard let (data, response) = try? await postMembership(codingUsagesURL, token: token, body: requestBody),
              (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data),
              let usages = json["usages"] as? [[String: Any]],
              let coding = usages.first(where: { ($0["scope"] as? String) == "FEATURE_CODING" })
        else { return nil }

        var windows: [QuotaWindow] = []

        if let detail = coding["detail"] as? [String: Any] {
            let used = usedPercent(from: detail)
            let reset = JSONPath.string(detail["resetTime"])
                ?? JSONPath.string(detail["reset_time"])
            windows.append(QuotaWindow(
                kind: .sevenDay,
                title: "Code",
                usedPercent: used,
                resetsAt: reset.flatMap(parseDate)
            ))
        }

        if let limits = coding["limits"] as? [[String: Any]] {
            for limit in limits {
                let window = limit["window"] as? [String: Any]
                let duration = JSONPath.double(window?["duration"]) ?? 0
                let unit = ((window?["timeUnit"] as? String) ?? (window?["time_unit"] as? String) ?? "").uppercased()
                let detail = (limit["detail"] as? [String: Any]) ?? [:]
                let used = usedPercent(from: detail)
                let reset = JSONPath.string(detail["resetTime"])
                    ?? JSONPath.string(detail["reset_time"])
                if duration == 300 && unit.contains("MINUTE") {
                    windows.append(QuotaWindow(
                        kind: .fiveHour,
                        title: "Code",
                        usedPercent: used,
                        resetsAt: reset.flatMap(parseDate)
                    ))
                }
            }
        }

        return windows.isEmpty ? nil : windows
    }

    private static func usedPercent(from detail: [String: Any]) -> Double? {
        let limit = JSONPath.double(detail["limit"])
        if let used = JSONPath.double(detail["used"]), let limit, limit > 0 {
            return used / limit * 100
        }
        if let remaining = JSONPath.double(detail["remaining"]), let limit, limit > 0 {
            return (1 - remaining / limit) * 100
        }
        return nil
    }

    private static func postMembership(
        _ url: URL,
        token: String,
        body: Data = Data("{}".utf8)
    ) async throws -> (Data, HTTPURLResponse) {
        var headers: [String: String] = [
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
        if let session = decodeSession(token) {
            if let deviceId = session.deviceId { headers["x-msh-device-id"] = deviceId }
            if let sessionId = session.sessionId { headers["x-msh-session-id"] = sessionId }
            if let trafficId = session.trafficId { headers["x-traffic-id"] = trafficId }
        }
        return try await HTTP.post(url, headers: headers, body: body)
    }

    private static func fetchPlanName(token: String) async -> String? {
        guard let (data, response) = try? await postMembership(subscriptionURL, token: token),
              (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data)
        else { return nil }

        // Flexible paths for plan name.
        let candidates: [Any?] = [
            json["productName"],
            json["planName"],
            json["name"],
            (json["subscription"] as? [String: Any])?["productName"],
            (json["subscription"] as? [String: Any])?["planName"],
            (json["product"] as? [String: Any])?["name"],
            (json["membership"] as? [String: Any])?["level"]
        ]
        for c in candidates {
            if let s = c as? String, !s.isEmpty { return prettyPlan(s) }
        }
        return nil
    }

    private static func mapSubscriptionStats(_ json: [String: Any]) -> QuotaSnapshot? {
        let balance = (json["subscriptionBalance"] as? [String: Any])
            ?? (json["subscription_balance"] as? [String: Any])
        guard let balance else { return nil }

        // amountUsedRatio is fraction used (0.3575 → 35.75% used on the website).
        let usedRatio = JSONPath.double(balance["amountUsedRatio"])
            ?? JSONPath.double(balance["amount_used_ratio"])
        guard let usedRatio else { return nil }

        let usedPercent = usedRatio <= 1.0001 ? usedRatio * 100 : usedRatio
        let remaining = max(0, min(100, 100 - usedPercent))

        let expire = JSONPath.string(balance["expireTime"])
            ?? JSONPath.string(balance["expire_time"])
        let monthReset = expire.flatMap(parseDate)

        var windows: [QuotaWindow] = [
            QuotaWindow(
                kind: .thirtyDay,
                title: "总使用量",
                usedPercent: usedPercent,
                resetsAt: monthReset
            )
        ]

        // Code 5h / 7d rate limits from the same membership stats payload.
        // Note: when a window is at 0% used, Kimi often omits `ratio` entirely.
        func appendCodeLimit(keyCandidates: [String], kind: QuotaWindowKind, title: String) {
            for key in keyCandidates {
                guard let row = json[key] as? [String: Any] else { continue }
                let ratio = JSONPath.double(row["ratio"])
                let used: Double?
                if let ratio {
                    used = ratio <= 1.0001 ? ratio * 100 : ratio
                } else if row["enabled"] as? Bool == true {
                    used = 0
                } else {
                    used = nil
                }
                let reset = JSONPath.string(row["resetTime"])
                    ?? JSONPath.string(row["reset_time"])
                    ?? JSONPath.string(row["expireTime"])
                windows.append(QuotaWindow(
                    kind: kind,
                    title: title,
                    usedPercent: used,
                    resetsAt: reset.flatMap(parseDate)
                ))
                return
            }
        }

        appendCodeLimit(
            keyCandidates: ["ratelimitCode5h", "ratelimit_code_5h", "rateLimitCode5h"],
            kind: .fiveHour,
            title: "Code"
        )
        appendCodeLimit(
            keyCandidates: ["ratelimitCode7d", "ratelimit_code_7d", "rateLimitCode7d"],
            kind: .sevenDay,
            title: "Code"
        )

        windows.sort { $0.kind.sortOrder < $1.kind.sortOrder }

        let codeUsed = windows
            .filter { ($0.title ?? "").localizedCaseInsensitiveContains("code") }
            .compactMap(\.usedPercent)
            .max()

        let detail = String(format: "总使用量 %.2f%%", usedPercent)
        let metrics = QuotaMetrics(
            cursorModelsUsed: nil,
            otherModelsUsed: nil,
            kimiMembershipUsed: usedPercent,
            kimiCodeUsed: codeUsed
        )

        return QuotaSnapshot(
            provider: .kimi,
            remainingPercent: remaining,
            detail: detail,
            planName: nil,
            windows: windows,
            updatedAt: Date(),
            error: nil,
            metrics: metrics
        )
    }

    private static func prettyPlan(_ raw: String) -> String {
        switch raw {
        case "LEVEL_FREE": return "Free"
        case "LEVEL_BASIC": return "Adagio"
        case "LEVEL_STANDARD": return "Moderato"
        case "LEVEL_INTERMEDIATE": return "Allegretto"
        case "LEVEL_ADVANCED": return "Allegro"
        case "LEVEL_PREMIUM": return "Vivace"
        default: return raw
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: value) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: value) { return d }

        // Kimi sometimes returns >3 fractional digits; trim to milliseconds.
        if let dot = value.firstIndex(of: "."),
           let z = value.lastIndex(of: "Z"),
           z > dot {
            let frac = value[value.index(after: dot)..<z]
            let trimmed = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            let normalized = String(value[..<value.index(after: dot)]) + trimmed + "Z"
            if let d = isoFrac.date(from: normalized) { return d }
        }
        return nil
    }

    private struct SessionInfo {
        var deviceId: String?
        var sessionId: String?
        var trafficId: String?
    }

    private static func decodeSession(_ jwt: String) -> SessionInfo? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return SessionInfo(
            deviceId: json["device_id"] as? String,
            sessionId: json["ssid"] as? String,
            trafficId: json["sub"] as? String
        )
    }
}
