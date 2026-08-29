import Foundation

enum UsageHighWaterMerge {
    static func day(_ first: DailyUsage?, _ second: DailyUsage?) -> DailyUsage? {
        switch (first, second) {
        case (nil, nil):
            return nil
        case (let only?, nil):
            return only.totalTokens > 0 ? only : nil
        case (nil, let only?):
            return only.totalTokens > 0 ? only : nil
        case (let lhs?, let rhs?):
            return mergeObservedDays(lhs, rhs)
        }
    }

    static func days(_ first: [DailyUsage], _ second: [DailyUsage]) -> [DailyUsage] {
        var merged: [String: DailyUsage] = [:]
        for row in first + second {
            merged[row.date] = day(merged[row.date], row)
        }
        return merged.values
            .filter { $0.totalTokens > 0 }
            .sorted { $0.date < $1.date }
    }

    static func totalTokens(_ daily: [DailyUsage]) -> Int {
        daily.filter { $0.totalTokens > 0 }.map(\.totalTokens).reduce(0, +)
    }

    static func isRicher(_ merged: [DailyUsage], than original: [DailyUsage]) -> Bool {
        totalTokens(merged) > totalTokens(original) || merged.count > original.count
    }

    private static func mergeObservedDays(_ lhs: DailyUsage, _ rhs: DailyUsage) -> DailyUsage {
        let tools = maxIntMap(lhs.tools, rhs.tools)
        var models = maxIntMap(lhs.models, rhs.models)
        var modelsByTool: [String: [String: Int]] = lhs.modelsByTool
        for (tool, incoming) in rhs.modelsByTool {
            modelsByTool[tool] = maxIntMap(modelsByTool[tool] ?? [:], incoming)
        }
        modelsByTool = modelsByTool
            .mapValues { $0.filter { $0.value > 0 } }
            .filter { !$0.value.isEmpty }
        if models.isEmpty {
            models = modelsByTool.values.reduce(into: [:]) { result, item in
                for (model, tokens) in item {
                    result[model] = max(result[model] ?? 0, tokens)
                }
            }
        }

        let toolCosts = maxDoubleMap(lhs.toolCosts, rhs.toolCosts)
        let modelCosts = maxDoubleMap(lhs.modelCosts, rhs.modelCosts)
        let totalTokens = tools.values.reduce(0, +)
        let resolvedTokens = totalTokens > 0 ? totalTokens : max(lhs.totalTokens, rhs.totalTokens)
        guard resolvedTokens > 0 else { return lhs }

        let cost = toolCosts.values.reduce(0, +)
        let equivalent = toolCosts.isEmpty
            ? max(lhs.equivalentCost, rhs.equivalentCost, lhs.cost, rhs.cost)
            : cost
        return DailyUsage(
            date: lhs.date,
            tools: tools,
            models: models,
            modelsByTool: modelsByTool,
            totalTokens: resolvedTokens,
            cost: max(lhs.cost, rhs.cost, cost),
            equivalentCost: equivalent,
            modelCosts: modelCosts,
            toolCosts: toolCosts
        )
    }

    private static func maxIntMap(_ lhs: [String: Int], _ rhs: [String: Int]) -> [String: Int] {
        var result = lhs
        for (key, value) in rhs {
            result[key] = max(result[key] ?? 0, value)
        }
        return result.filter { $0.value > 0 }
    }

    private static func maxDoubleMap(_ lhs: [String: Double], _ rhs: [String: Double]) -> [String: Double] {
        var result = lhs
        for (key, value) in rhs {
            result[key] = max(result[key] ?? 0, value)
        }
        return result.filter { $0.value > 0 }
    }
}
