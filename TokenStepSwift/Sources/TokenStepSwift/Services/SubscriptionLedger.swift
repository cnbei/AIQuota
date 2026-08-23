import Foundation

struct SubscriptionMonthSummary: Equatable, Sendable {
    var estimatedCostUSD: Double
    var planAmount: Double
    var currency: SubscriptionCurrency
    var planCount: Int
    var ratio: Double?
    var mixedPlanLabel: String? = nil

    var estimatedText: String {
        TokenStepFormat.money(
            SubscriptionLedger.convert(usd: estimatedCostUSD, to: currency),
            currency: currency
        )
    }

    var planText: String {
        if let mixedPlanLabel, !mixedPlanLabel.isEmpty {
            return mixedPlanLabel
        }
        return TokenStepFormat.money(planAmount, currency: currency)
    }

    var headline: String {
        guard planCount > 0 else { return "" }
        if let ratio, mixedPlanLabel == nil {
            return String(format: "%@ · %@ · %.2f×", estimatedText, planText, ratio)
        }
        return "\(estimatedText) · \(planText)"
    }
}

enum SubscriptionLedger {
    /// 手填人民币时，把本机美元估算约合成人民币。不联网、不随行情变。
    static let usdToCny = 7.2

    static func convert(usd: Double, to currency: SubscriptionCurrency) -> Double {
        switch currency {
        case .usd:
            return usd
        case .cny:
            return usd * usdToCny
        }
    }

    static func convertToUSD(amount: Double, currency: SubscriptionCurrency) -> Double {
        switch currency {
        case .usd:
            return amount
        case .cny:
            return amount / usdToCny
        }
    }

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
            return ["Grok", "Grok Build", "Grok CLI"]
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
        let estimated = estimatedCost(in: snapshot, monthPrefix: prefix)
        let currencies = Set(active.map(\.currency))
        if currencies.count <= 1 {
            let currency = active.first?.currency ?? .usd
            let planTotal = active.reduce(0) { $0 + $1.monthlyPrice }
            return SubscriptionMonthSummary(
                estimatedCostUSD: estimated,
                planAmount: planTotal,
                currency: currency,
                planCount: active.count,
                ratio: planTotal > 0 ? convert(usd: estimated, to: currency) / planTotal : nil
            )
        }

        let parts = SubscriptionCurrency.allCases.compactMap { currency -> String? in
            let total = active.filter { $0.currency == currency }.reduce(0) { $0 + $1.monthlyPrice }
            guard total > 0 else { return nil }
            return TokenStepFormat.money(total, currency: currency)
        }
        let planTotalUSD = active.reduce(0) { $0 + convertToUSD(amount: $1.monthlyPrice, currency: $1.currency) }
        return SubscriptionMonthSummary(
            estimatedCostUSD: estimated,
            planAmount: planTotalUSD,
            currency: .usd,
            planCount: active.count,
            ratio: planTotalUSD > 0 ? estimated / planTotalUSD : nil,
            mixedPlanLabel: parts.joined(separator: " + ")
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
            planAmount: plan.monthlyPrice,
            currency: plan.currency,
            planCount: 1,
            ratio: plan.monthlyPrice > 0 ? convert(usd: estimated, to: plan.currency) / plan.monthlyPrice : nil
        )
    }
}
