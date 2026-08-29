import Foundation

enum UsageDayDate {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum UsageHistoryLedger {
    static func merge(
        collected: UsageSnapshot,
        previous: UsageSnapshot?,
        now: Date = Date()
    ) -> UsageSnapshot {
        _ = now
        let daily = UsageHighWaterMerge.days(previous?.daily ?? [], collected.daily)

        var rhythms = Dictionary(
            uniqueKeysWithValues: (previous?.rhythms ?? [])
                .filter { $0.totalTokens > 0 }
                .map { ($0.date, $0) }
        )
        for row in collected.rhythms where row.totalTokens > 0 {
            if let stored = rhythms[row.date], stored.totalTokens > row.totalTokens {
                continue
            }
            rhythms[row.date] = row
        }

        var agentWork = Dictionary(
            uniqueKeysWithValues: (previous?.agentWork ?? [])
                .filter { $0.totalTokens > 0 }
                .map { ($0.date, $0) }
        )
        for row in collected.agentWork where row.totalTokens > 0 {
            if let stored = agentWork[row.date], stored.totalTokens > row.totalTokens {
                continue
            }
            agentWork[row.date] = row
        }

        return recompute(
            daily: daily,
            rhythms: daily.compactMap { rhythms[$0.date] },
            agentWork: daily.compactMap { agentWork[$0.date] },
            collected: collected
        )
    }

    static func mergeDay(live: DailyUsage?, stored: DailyUsage?) -> DailyUsage? {
        UsageHighWaterMerge.day(stored, live)
    }

    private static func recompute(
        daily: [DailyUsage],
        rhythms: [DailyRhythm],
        agentWork: [DailyAgentWork],
        collected: UsageSnapshot
    ) -> UsageSnapshot {
        var toolTokens: [String: Int] = [:]
        var modelTokens: [String: (tool: String?, tokens: Int)] = [:]
        var totalCost = 0.0
        for day in daily {
            for (tool, tokens) in day.tools {
                toolTokens[tool, default: 0] += tokens
            }
            if !day.modelsByTool.isEmpty {
                for (tool, models) in day.modelsByTool {
                    for (model, tokens) in models {
                        let key = "\(tool)\u{1e}\(model)"
                        let current = modelTokens[key]?.tokens ?? 0
                        modelTokens[key] = (tool, current + tokens)
                    }
                }
            } else {
                for (model, tokens) in day.models {
                    let current = modelTokens[model]?.tokens ?? 0
                    modelTokens[model] = (nil, current + tokens)
                }
            }
            totalCost += day.displayCost
        }

        let totalTokens = toolTokens.values.reduce(0, +)
        let tools = toolTokens
            .sorted { $0.value > $1.value }
            .map { tool, tokens in
                ToolUsage(
                    tool: tool,
                    tokens: tokens,
                    percent: totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0
                )
            }
        let models = modelTokens
            .sorted { $0.value.tokens > $1.value.tokens }
            .map { key, item in
                let model = item.tool == nil ? key : String(key.split(separator: "\u{1e}").last ?? Substring(key))
                return ModelUsage(
                    model: model,
                    tool: item.tool,
                    tokens: item.tokens,
                    percent: totalTokens > 0 ? Double(item.tokens) / Double(totalTokens) : 0
                )
            }

        return UsageSnapshot(
            generatedAt: collected.generatedAt,
            timezone: collected.timezone,
            totals: UsageTotals(
                tokens: totalTokens,
                cost: (totalCost * 100).rounded() / 100,
                activeDays: daily.filter { $0.totalTokens > 0 }.count
            ),
            daily: daily,
            rhythms: rhythms.sorted { $0.date < $1.date },
            agentWork: agentWork.sorted { $0.date < $1.date },
            tools: tools,
            models: models,
            sources: collected.sources
        )
    }
}

struct GoalStreak: Equatable {
    var current: Int
    var longest: Int
    var todayReached: Bool

    var popoverHeadline: String {
        if todayReached {
            return LFormat("已连续 %d 天达标", current)
        }
        if current > 0 {
            return LFormat("已连续 %d 天 · 今天进行中", current)
        }
        return L("今天还没达标")
    }

    static func compute(
        daily: [DailyUsage],
        goal: Int,
        today: String
    ) -> GoalStreak {
        let safeGoal = max(1, goal)
        let met = Set(daily.filter { $0.totalTokens >= safeGoal }.map(\.date))
        let todayReached = met.contains(today)
        return GoalStreak(
            current: currentStreak(met: met, today: today, todayReached: todayReached),
            longest: longestStreak(dates: met),
            todayReached: todayReached
        )
    }

    private static func currentStreak(met: Set<String>, today: String, todayReached: Bool) -> Int {
        guard let todayDate = UsageDayDate.formatter.date(from: today) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var cursor = todayDate
        if !todayReached {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: todayDate) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while true {
            let key = UsageDayDate.formatter.string(from: cursor)
            guard met.contains(key) else { break }
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func longestStreak(dates: Set<String>) -> Int {
        let sorted = dates.sorted()
        guard !sorted.isEmpty else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var best = 1
        var run = 1
        for index in 1..<sorted.count {
            guard
                let previous = UsageDayDate.formatter.date(from: sorted[index - 1]),
                let current = UsageDayDate.formatter.date(from: sorted[index]),
                let expected = calendar.date(byAdding: .day, value: 1, to: previous),
                calendar.isDate(current, inSameDayAs: expected)
            else {
                run = 1
                continue
            }
            run += 1
            best = max(best, run)
        }
        return best
    }
}
