import Foundation

struct SubscriptionMonthSummary: Equatable, Sendable {
    var estimatedCostUSD: Double
    var planTotalUSD: Double
    var planCount: Int
    var ratio: Double?

    var headline: String {
        guard planCount > 0 else { return "" }
        let estimate = TokenStepFormat.money(estimatedCostUSD)
        let plan = TokenStepFormat.money(planTotalUSD)
        if let ratio {
            return String(format: "%@ · %@ · %.2f×", estimate, plan, ratio)
        }
        return "\(estimate) · \(plan)"
    }
}

enum SubscriptionLedger {
    static func monthPrefix(
        now: Date,
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: now)
    }

    static func toolNames(for provider: QuotaProviderID) -> [String] {
        switch provider {
        case .codex:
            return ["Codex", "Codex via CC Switch"]
        case .claude:
            return ["Claude Code", "Claude Code via CC Switch"]
        case .cursor:
            return ["Cursor"]
        case .glm:
            return ["GLM"]
        case .kimi:
            return ["Kimi", "Kimi Code"]
        case .grok:
            return ["Grok", "Grok CLI"]
        }
    }

    static func estimatedCost(
        in snapshot: UsageSnapshot,
        monthPrefix: String,
        matching tools: [String]? = nil
    ) -> Double {
        snapshot.daily
            .filter { $0.date.hasPrefix(monthPrefix) }
            .reduce(0) { total, day in
                guard let tools else {
                    return total + day.displayCost
                }
                return total + tools.reduce(0) { $0 + (day.toolCosts[$1] ?? 0) }
            }
    }

    static func summary(
        plans: [SubscriptionPlan],
        snapshot: UsageSnapshot,
        now: Date = Date()
    ) -> SubscriptionMonthSummary {
        let prefix = monthPrefix(now: now)
        let active = SubscriptionPlan.normalized(plans)
        let planTotal = active.reduce(0) { $0 + $1.monthlyPrice }
        let estimated = estimatedCost(in: snapshot, monthPrefix: prefix)
        return SubscriptionMonthSummary(
            estimatedCostUSD: estimated,
            planTotalUSD: planTotal,
            planCount: active.count,
            ratio: planTotal > 0 ? estimated / planTotal : nil
        )
    }

    static func providerSummary(
        provider: QuotaProviderID,
        plans: [SubscriptionPlan],
        snapshot: UsageSnapshot,
        now: Date = Date()
    ) -> SubscriptionMonthSummary? {
        guard let plan = plans.first(where: { $0.provider == provider && $0.monthlyPrice > 0 }) else {
            return nil
        }
        let prefix = monthPrefix(now: now)
        let estimated = estimatedCost(
            in: snapshot,
            monthPrefix: prefix,
            matching: toolNames(for: provider)
        )
        return SubscriptionMonthSummary(
            estimatedCostUSD: estimated,
            planTotalUSD: plan.monthlyPrice,
            planCount: 1,
            ratio: plan.monthlyPrice > 0 ? estimated / plan.monthlyPrice : nil
        )
    }
}
