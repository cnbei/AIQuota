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

            guard let snap = mapSubscriptionStats(json) else {
                return .failed(.kimi, message: "无法解析总使用量字段")
            }

            // Best-effort plan name enrichment.
            if snap.planName == nil,
               let plan = await fetchPlanName(token: token) {
                return QuotaSnapshot(
                    provider: snap.provider,
                    remainingPercent: snap.remainingPercent,
                    detail: snap.detail,
                    planName: plan,
                    updatedAt: snap.updatedAt,
                    error: nil
                )
            }
            return snap
        } catch {
            return .failed(.kimi, message: error.localizedDescription)
        }
    }

    private static func postMembership(_ url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
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
        return try await HTTP.post(url, headers: headers, body: Data("{}".utf8))
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
        var detail = String(format: "总使用量 %.2f%%", usedPercent)
        if let expire, let date = parseDate(expire) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            detail += " · 重置 \(f.string(from: date))"
        }

        // Optional Code sub-limits if present (for detail only).
        if let code7d = json["ratelimitCode7d"] as? [String: Any]
            ?? json["ratelimit_code_7d"] as? [String: Any],
           let ratio = JSONPath.double(code7d["ratio"]) {
            let codeUsed = ratio <= 1.0001 ? ratio * 100 : ratio
            detail += String(format: " · Code7d %.2f%%", codeUsed)
        }

        return QuotaSnapshot(
            provider: .kimi,
            remainingPercent: remaining,
            detail: detail,
            planName: nil,
            updatedAt: Date(),
            error: nil
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
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: value) { return d }
        return ISO8601DateFormatter().date(from: value)
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
