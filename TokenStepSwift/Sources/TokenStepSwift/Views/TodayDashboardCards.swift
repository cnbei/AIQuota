import SwiftUI

struct TodayHeroCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let lap = appState.todayLap
        TokenCard {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    ProgressRingView(progress: lap.currentLapProgress, lineWidth: 16, color: lap.ringColor)
                    VStack(spacing: 4) {
                        Text(TokenStepFormat.tokens(appState.today.totalTokens))
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.tokenInk)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text(LFormat("/ %@ 每圈", TokenStepFormat.tokens(appState.settings.dailyGoalTokens, compact: true)))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.tokenMuted)
                    }
                    .frame(width: 100)
                }
                .frame(width: 132, height: 132)

                VStack(alignment: .leading, spacing: 10) {
                    Text(lap.lapStatusText)
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                    Text(heroSubtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        metricChips
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var heroSubtitle: String {
        let today = DateFormatter.tokenStepDay.string(from: Date())
        return LFormat("今日 %@ · 已达标 %d 圈", today, appState.todayLap.completedLaps)
    }

    @ViewBuilder
    private var metricChips: some View {
        TodayMetricChip(label: L("约合美元"), value: TokenStepFormat.money(appState.today.displayCost))
        TodayMetricChip(label: L("连续达标"), value: LFormat("%d 天", appState.goalStreak.current))
        TodayMetricChip(label: L("最长连续"), value: LFormat("%d 天", appState.goalStreak.longest))
        TodayMetricChip(label: L("达标天"), value: LFormat("%d 天", appState.goalDays))
    }
}

struct TodayAgentIntensityCard: View {
    @EnvironmentObject private var appState: AppState

    private var work: DailyAgentWork {
        appState.todayAgentWork
    }

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Agent 工作强度"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("本版补全：请求数 / 工具调用 / 输出"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                }

                HStack(spacing: 8) {
                    TodayBigStat(label: L("模型请求"), value: compactCount(work.modelRequestCount))
                    TodayBigStat(label: L("工具调用"), value: compactCount(work.toolCallCount))
                    TodayBigStat(label: L("缓存命中"), value: cacheRateText)
                }

                VStack(spacing: 0) {
                    TodayKVRow(label: L("输入"), value: TokenStepFormat.tokens(work.inputTokens, compact: true))
                    TodayKVRow(label: L("缓存读取"), value: TokenStepFormat.tokens(work.cachedInputTokens, compact: true))
                    TodayKVRow(label: L("输出"), value: TokenStepFormat.tokens(work.outputTokens, compact: true))
                }
            }
        }
    }

    private var cacheRateText: String {
        if let rate = work.cacheHitRate {
            return TokenStepFormat.percent(rate * 100)
        }
        return "--"
    }

    private func compactCount(_ value: Int) -> String {
        TokenStepFormat.tokens(value, compact: true)
    }
}

struct TodayHourlyCard: View {
    @EnvironmentObject private var appState: AppState

    private var work: DailyAgentWork {
        appState.todayAgentWork
    }

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("今日分时"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("来自 hourlyBuckets · 活跃小时由此重算"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                }

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { hour in
                        let tokens = work.bucket(hour: hour).totalTokens
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.tokenGreen, Color.tokenGreenDark],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(maxWidth: .infinity, minHeight: 3, maxHeight: barHeight(tokens))
                            .opacity(tokens > 0 ? 1 : 0.18)
                    }
                }
                .frame(height: 78, alignment: .bottom)

                HStack {
                    Text("0")
                    Spacer()
                    Text("6")
                    Spacer()
                    Text("12")
                    Spacer()
                    Text("18")
                    Spacer()
                    Text("23")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tokenMuted)

                if work.unbucketedTokens > 0 {
                    Text(LFormat("无时间戳 %@ 已单列，不摊进任何小时。", TokenStepFormat.tokens(work.unbucketedTokens, compact: true)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                }
            }
        }
    }

    private func barHeight(_ tokens: Int) -> CGFloat {
        let maxTokens = max(1, work.hourlyBuckets.map(\.totalTokens).max() ?? 0)
        guard tokens > 0 else { return 3 }
        return max(6, 78 * CGFloat(tokens) / CGFloat(maxTokens))
    }
}

struct TodaySourcesCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("今日来源"))
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Color.tokenInk)
                    Text(L("各客户端下的模型 · 约合美元按公开价估算"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                }

                if rows.isEmpty {
                    Text(L("等待下一次同步"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                } else {
                    VStack(spacing: 10) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle()
                                        .fill(row.color ?? Color.tokenInk.opacity(0.35))
                                        .frame(width: 8, height: 8)
                                    Text(row.name)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(Color.tokenInk)
                                    Spacer()
                                    Text(TokenStepFormat.tokens(row.tokens, compact: true))
                                        .font(.callout.weight(.heavy))
                                        .foregroundStyle(Color.tokenInk)
                                        .monospacedDigit()
                                    if row.cost > 0 {
                                        Text(TokenStepFormat.money(row.cost))
                                            .font(.callout.weight(.heavy))
                                            .foregroundStyle(Color.tokenInk)
                                            .monospacedDigit()
                                    }
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.tokenTrack)
                                        Capsule()
                                            .fill(row.color ?? Color.tokenInk.opacity(0.35))
                                            .frame(width: max(4, proxy.size.width * min(max(row.percent, 0), 100) / 100))
                                    }
                                }
                                .frame(height: 5)

                                if !row.models.isEmpty {
                                    VStack(spacing: 4) {
                                        ForEach(row.models) { model in
                                            HStack(spacing: 6) {
                                                Text(model.name)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(Color.tokenMuted)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(TokenStepFormat.tokens(model.tokens, compact: true))
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(Color.tokenMuted)
                                                    .monospacedDigit()
                                                Text(TokenStepFormat.money(model.cost))
                                                    .font(.caption.weight(.heavy))
                                                    .foregroundStyle(Color.tokenInk)
                                                    .monospacedDigit()
                                            }
                                            .padding(.leading, 16)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var rows: [TodayBreakdownRow] {
        TodaySourceRows.make(
            tools: appState.today.tools,
            models: appState.today.models,
            modelsByTool: appState.today.modelsByTool,
            modelCosts: appState.today.resolvedModelCosts,
            toolCosts: appState.today.toolCosts
        )
    }
}

struct TodayModelCostCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TokenCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("今日约合"))
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Color.tokenInk)
                        Text(L("按公开价估算 · 不同模型单价不同"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tokenMuted)
                    }
                    Spacer()
                    Text(TokenStepFormat.money(totalCost))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.tokenInk)
                        .monospacedDigit()
                }

                if rows.isEmpty {
                    Text(L("等待下一次同步"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.tokenMuted)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                } else {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle()
                                        .fill(row.color ?? Color.tokenInk.opacity(0.35))
                                        .frame(width: 8, height: 8)
                                    Text(row.name)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(Color.tokenInk)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(TokenStepFormat.tokens(row.tokens, compact: true))
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.tokenMuted)
                                        .monospacedDigit()
                                    Text(TokenStepFormat.money(row.cost))
                                        .font(.callout.weight(.heavy))
                                        .foregroundStyle(Color.tokenInk)
                                        .monospacedDigit()
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.tokenTrack)
                                        Capsule()
                                            .fill(row.color ?? Color.tokenInk.opacity(0.35))
                                            .frame(width: max(4, proxy.size.width * min(max(row.percent, 0), 100) / 100))
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rows: [TodayModelCostRow] {
        TodayModelCostRows.make(
            models: appState.today.models,
            modelCosts: appState.today.resolvedModelCosts
        )
    }

    private var totalCost: Double {
        let summed = rows.map(\.cost).reduce(0, +)
        return summed > 0 ? summed : appState.today.displayCost
    }
}

enum TodayModelCostRows {
    static func make(
        models: [String: Int],
        modelCosts: [String: Double],
        maxNamed: Int = 4
    ) -> [TodayModelCostRow] {
        let costs = models.reduce(into: [String: Double]()) { result, item in
            guard item.value > 0 else { return }
            if let stored = modelCosts[item.key], stored > 0 {
                result[item.key] = stored
            } else {
                result[item.key] = ModelPricing.cost(
                    model: item.key,
                    inputTokens: 0,
                    outputTokens: 0,
                    totalTokens: item.value
                )
            }
        }
        let totalCost = costs.values.reduce(0, +)
        guard totalCost > 0 else { return [] }
        let ranked = costs
            .map { model, cost in
                (model: model, tokens: models[model] ?? 0, cost: cost)
            }
            .sorted {
                if $0.cost != $1.cost { return $0.cost > $1.cost }
                return $0.tokens > $1.tokens
            }
        let named = Array(ranked.prefix(maxNamed))
        let rest = Array(ranked.dropFirst(maxNamed))
        var rows = named.enumerated().map { index, entry in
            TodayModelCostRow(
                model: entry.model,
                name: ModelPricing.displayName(for: entry.model),
                tokens: entry.tokens,
                cost: entry.cost,
                percent: entry.cost * 100 / totalCost,
                color: tokenModelColor(index: index)
            )
        }
        if !rest.isEmpty {
            let tokens = rest.map(\.tokens).reduce(0, +)
            let cost = rest.map(\.cost).reduce(0, +)
            rows.append(
                TodayModelCostRow(
                    model: rest.map(\.model).sorted().joined(separator: ","),
                    name: LFormat("其他 %d 个模型", rest.count),
                    tokens: tokens,
                    cost: cost,
                    percent: cost * 100 / totalCost,
                    color: Color.tokenInk.opacity(0.35)
                )
            )
        }
        return rows
    }
}

struct TodayModelCostRow: Identifiable {
    var model: String
    var name: String
    var tokens: Int
    var cost: Double
    var percent: Double
    var color: Color?

    var id: String { model.isEmpty ? name : model }
}

private func tokenModelColor(index: Int) -> Color {
    let palette: [Color] = [
        Color.tokenGreenDark,
        Color(red: 0.18, green: 0.45, blue: 0.82),
        Color(red: 0.90, green: 0.55, blue: 0.18),
        Color(red: 0.58, green: 0.35, blue: 0.86)
    ]
    return palette[index % palette.count]
}

enum TodaySourceRows {
    static func make(
        tools: [String: Int],
        models: [String: Int] = [:],
        modelsByTool: [String: [String: Int]] = [:],
        modelCosts: [String: Double] = [:],
        toolCosts: [String: Double] = [:],
        maxNamed: Int = 3,
        maxModels: Int = 4
    ) -> [TodayBreakdownRow] {
        let total = tools.values.reduce(0, +)
        guard total > 0 else { return [] }
        let grouped = modelsByTool.isEmpty ? assignModels(models, to: tools) : modelsByTool
        let ranked = orderedToolEntries(tools)
        let named = Array(ranked.prefix(maxNamed))
        let rest = Array(ranked.dropFirst(maxNamed))
        var rows = named.map { entry in
            let toolModels = grouped[entry.name] ?? [:]
            return TodayBreakdownRow(
                name: entry.name,
                tokens: entry.tokens,
                percent: Double(entry.tokens) * 100 / Double(total),
                color: tokenToolColor(entry.name),
                cost: cost(forTool: entry.name, models: toolModels, toolCosts: toolCosts, modelCosts: modelCosts),
                models: modelRows(models: toolModels, modelCosts: modelCosts, maxNamed: maxModels)
            )
        }
        if !rest.isEmpty {
            let tokens = rest.map(\.tokens).reduce(0, +)
            let restModels = rest.reduce(into: [String: Int]()) { result, entry in
                for (model, modelTokens) in grouped[entry.name] ?? [:] {
                    result[model, default: 0] += modelTokens
                }
            }
            rows.append(
                TodayBreakdownRow(
                    name: LFormat("其他 %d 个来源", rest.count),
                    tokens: tokens,
                    percent: Double(tokens) * 100 / Double(total),
                    color: Color.tokenInk.opacity(0.35),
                    cost: rest.reduce(0) { $0 + cost(forTool: $1.name, models: grouped[$1.name] ?? [:], toolCosts: toolCosts, modelCosts: modelCosts) },
                    models: modelRows(models: restModels, modelCosts: modelCosts, maxNamed: maxModels)
                )
            )
        }
        return rows
    }

    static func assignModels(_ models: [String: Int], to tools: [String: Int]) -> [String: [String: Int]] {
        let available = Set(tools.keys)
        var result: [String: [String: Int]] = [:]
        for (model, tokens) in models where tokens > 0 {
            guard let tool = inferredTool(for: model, available: available) else { continue }
            result[tool, default: [:]][model, default: 0] += tokens
        }
        return result
    }

    static func inferredTool(for model: String, available: Set<String>) -> String? {
        let key = model.lowercased()
        if available.contains("Cursor"), isCursorModel(key) { return "Cursor" }
        if available.contains("Codex"), isCodexModel(key) { return "Codex" }
        if available.contains("Claude Code"), isClaudeModel(key) { return "Claude Code" }
        if available.contains("Antigravity"), isGeminiModel(key) { return "Antigravity" }
        if available.contains("Codex via CC Switch"), isCodexModel(key) { return "Codex via CC Switch" }
        if available.contains("Claude Code via CC Switch"), isClaudeModel(key) { return "Claude Code via CC Switch" }
        return available.count == 1 ? available.first : nil
    }

    private static func isCursorModel(_ key: String) -> Bool {
        key.contains("grok") || key.contains("fable") || key.contains("composer") || key.contains("cursor")
    }

    private static func isCodexModel(_ key: String) -> Bool {
        key.contains("gpt") || key.contains("codex")
    }

    private static func isClaudeModel(_ key: String) -> Bool {
        key.contains("claude") || key.contains("sonnet") || key.contains("opus") || key.contains("haiku")
    }

    private static func isGeminiModel(_ key: String) -> Bool {
        key.contains("gemini") || key.contains("antigravity")
    }

    private static func cost(
        forTool tool: String,
        models: [String: Int],
        toolCosts: [String: Double],
        modelCosts: [String: Double]
    ) -> Double {
        if let stored = toolCosts[tool], stored > 0 {
            return stored
        }
        return models.reduce(0) { $0 + resolvedCost(model: $1.key, tokens: $1.value, modelCosts: modelCosts) }
    }

    private static func modelRows(
        models: [String: Int],
        modelCosts: [String: Double],
        maxNamed: Int
    ) -> [TodayModelCostRow] {
        let ranked = models
            .filter { $0.value > 0 }
            .map { model, tokens in
                (model: model, tokens: tokens, cost: resolvedCost(model: model, tokens: tokens, modelCosts: modelCosts))
            }
            .sorted {
                if $0.cost != $1.cost { return $0.cost > $1.cost }
                return $0.tokens > $1.tokens
            }
        guard !ranked.isEmpty else { return [] }
        let named = Array(ranked.prefix(maxNamed))
        let rest = Array(ranked.dropFirst(maxNamed))
        var rows = named.map { entry in
            TodayModelCostRow(
                model: entry.model,
                name: ModelPricing.displayName(for: entry.model),
                tokens: entry.tokens,
                cost: entry.cost,
                percent: 0
            )
        }
        if !rest.isEmpty {
            rows.append(
                TodayModelCostRow(
                    model: rest.map(\.model).sorted().joined(separator: ","),
                    name: LFormat("其他 %d 个模型", rest.count),
                    tokens: rest.map(\.tokens).reduce(0, +),
                    cost: rest.map(\.cost).reduce(0, +),
                    percent: 0
                )
            )
        }
        return rows
    }

    private static func resolvedCost(model: String, tokens: Int, modelCosts: [String: Double]) -> Double {
        if let stored = modelCosts[model], stored > 0 {
            return stored
        }
        return ModelPricing.cost(model: model, inputTokens: 0, outputTokens: 0, totalTokens: tokens)
    }
}

private struct TodayMetricChip: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.tokenMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.tokenTrack.opacity(0.42), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.black.opacity(0.04)))
    }
}

private struct TodayBigStat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.tokenMuted)
            Text(value)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.tokenInk)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodayKVRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.tokenInk)
            Spacer()
            Text(value)
                .font(.callout.weight(.heavy))
                .foregroundStyle(Color.tokenInk)
                .monospacedDigit()
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1)
        }
    }
}
