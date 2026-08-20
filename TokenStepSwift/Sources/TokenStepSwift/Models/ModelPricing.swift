import Foundation

struct ModelTokenRate: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double

    static func anthropic(input: Double, output: Double) -> ModelTokenRate {
        ModelTokenRate(
            input: input,
            output: output,
            cacheRead: input * 0.1,
            cacheWrite: input * 1.25
        )
    }

    static func openAI(input: Double, output: Double, cachedInput: Double? = nil) -> ModelTokenRate {
        ModelTokenRate(
            input: input,
            output: output,
            cacheRead: cachedInput ?? input * 0.1,
            cacheWrite: input
        )
    }
}

enum ModelPricing {
    static func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        totalTokens: Int = 0,
        inputIncludesCache: Bool = false
    ) -> Double {
        let cachedRead = max(0, cacheReadTokens)
        let cachedWrite = max(0, cacheWriteTokens)
        let uncachedInput: Int
        if inputIncludesCache {
            uncachedInput = max(0, inputTokens - cachedRead - cachedWrite)
        } else {
            uncachedInput = max(0, inputTokens)
        }

        if uncachedInput == 0, cachedRead == 0, cachedWrite == 0, outputTokens == 0 {
            let fallbackTokens = max(0, totalTokens)
            guard fallbackTokens > 0 else { return 0 }
            guard let rate = rate(for: model) else {
                return Double(fallbackTokens) / 1_000_000
            }
            return Double(fallbackTokens) / 1_000_000 * rate.input
        }

        guard let rate = rate(for: model) else {
            let counted = max(totalTokens, uncachedInput + cachedRead + cachedWrite + max(0, outputTokens))
            return Double(counted) / 1_000_000
        }

        return Double(uncachedInput) / 1_000_000 * rate.input
            + Double(max(0, outputTokens)) / 1_000_000 * rate.output
            + Double(cachedRead) / 1_000_000 * rate.cacheRead
            + Double(cachedWrite) / 1_000_000 * rate.cacheWrite
    }

    static func displayName(for model: String) -> String {
        let key = normalize(model)
        if key.contains("fable-5") || key.contains("fable5") { return "Fable 5" }
        if key.contains("grok-4.6") || key.contains("grok-4-6") {
            return grokDisplayName(version: "4.6", key: key)
        }
        if key.contains("grok-4.5") || key.contains("grok-4-5") {
            return grokDisplayName(version: "4.5", key: key)
        }
        if key.contains("composer-2.5") || key.contains("composer-2-5") {
            return key.contains("fast") ? "Composer 2.5 Fast" : "Composer 2.5"
        }
        if key.contains("composer-2") { return key.contains("fast") ? "Composer 2 Fast" : "Composer 2" }
        if key.contains("composer-1") { return "Composer 1" }
        if key.contains("gpt-5.4") || key.contains("gpt-5-4") { return "GPT-5.4" }
        if key.contains("gpt-5.5") || key.contains("gpt-5-5") { return "GPT-5.5" }
        if key.contains("gpt-5.3") || key.contains("gpt-5-3") { return "GPT-5.3" }
        if key.contains("gpt-5") { return "GPT-5" }
        return model
    }

    static func rate(for model: String) -> ModelTokenRate? {
        let key = normalize(model)

        if matches(key, ["grok-4.6-fast", "grok-4-6-fast"]) {
            return ModelTokenRate(input: 4, output: 12, cacheRead: 1, cacheWrite: 4)
        }
        if matches(key, ["grok-4.6", "grok-4-6"]) {
            return ModelTokenRate(input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2)
        }
        if matches(key, ["grok-4.5-fast", "grok-4-5-fast"]) {
            return ModelTokenRate(input: 4, output: 12, cacheRead: 1, cacheWrite: 4)
        }
        if matches(key, ["grok-4.5", "grok-4-5"]) {
            return ModelTokenRate(input: 2, output: 6, cacheRead: 0.5, cacheWrite: 2)
        }
        if matches(key, ["composer-2.5-fast", "composer-2-5-fast"]) {
            return ModelTokenRate(input: 3, output: 15, cacheRead: 0.5, cacheWrite: 3)
        }
        if matches(key, ["composer-2.5", "composer-2-5"]) {
            return ModelTokenRate(input: 0.5, output: 2.5, cacheRead: 0.2, cacheWrite: 0.5)
        }
        if key.contains("composer-2") && key.contains("fast") {
            return ModelTokenRate(input: 1.5, output: 7.5, cacheRead: 0.35, cacheWrite: 1.5)
        }
        if key.contains("composer-2") {
            return ModelTokenRate(input: 0.5, output: 2.5, cacheRead: 0.2, cacheWrite: 0.5)
        }
        if key.contains("composer-1.5") || key.contains("composer-1-5") {
            return ModelTokenRate(input: 3.5, output: 17.5, cacheRead: 0.35, cacheWrite: 3.5)
        }
        if key.contains("fable-5") || key.contains("fable5") {
            return .anthropic(input: 10, output: 50)
        }
        if key.contains("opus") && key.contains("fast") && (key.contains("4.7") || key.contains("4-7") || key.contains("opus-5")) {
            return .anthropic(input: 30, output: 150)
        }
        if key.contains("opus") {
            return .anthropic(input: 5, output: 25)
        }
        if key.contains("sonnet-5") || key.contains("sonnet 5") {
            return .anthropic(input: 2, output: 10)
        }
        if key.contains("haiku") {
            return .anthropic(input: 1, output: 5)
        }
        if key.contains("sonnet") {
            return .anthropic(input: 3, output: 15)
        }
        if key.contains("gpt-5.5") || key.contains("gpt-5-5") {
            return .openAI(input: 5, output: 30, cachedInput: 0.5)
        }
        if key.contains("gpt-5.4-nano") || key.contains("gpt-5-4-nano") {
            return .openAI(input: 0.2, output: 1.25, cachedInput: 0.02)
        }
        if key.contains("gpt-5.4-mini") || key.contains("gpt-5-4-mini") {
            return .openAI(input: 0.75, output: 4.5, cachedInput: 0.075)
        }
        if key.contains("gpt-5.4") || key.contains("gpt-5-4") {
            return .openAI(input: 2.5, output: 15, cachedInput: 0.25)
        }
        if key.contains("gpt-5.3") || key.contains("gpt-5-3") || key.contains("gpt-5.2") || key.contains("gpt-5-2") {
            return .openAI(input: 1.75, output: 14, cachedInput: 0.175)
        }
        if key.contains("gpt-5-mini") || key.contains("gpt-5.1-codex-mini") {
            return .openAI(input: 0.25, output: 2, cachedInput: 0.025)
        }
        if key.contains("gpt-5") {
            return .openAI(input: 1.25, output: 10, cachedInput: 0.125)
        }
        if key.contains("gemini-3.7-flash") {
            return ModelTokenRate(input: 0.75, output: 3.5, cacheRead: 0.075, cacheWrite: 0.75)
        }
        if key.contains("gemini-3.6-flash") {
            return ModelTokenRate(input: 1.5, output: 7.5, cacheRead: 0.15, cacheWrite: 1.5)
        }
        if key.contains("gemini-3.5-flash") {
            return ModelTokenRate(input: 1.5, output: 9, cacheRead: 0.15, cacheWrite: 1.5)
        }
        if key.contains("gemini-3-flash") || key.contains("gemini-3.0-flash") {
            return ModelTokenRate(input: 0.5, output: 3, cacheRead: 0.05, cacheWrite: 0.5)
        }
        if key.contains("gemini-2.5-flash") {
            return ModelTokenRate(input: 0.3, output: 2.5, cacheRead: 0.03, cacheWrite: 0.3)
        }
        if key.contains("gemini-3") {
            return ModelTokenRate(input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2)
        }
        if key.contains("glm") {
            return ModelTokenRate(input: 1.4, output: 4.4, cacheRead: 0.26, cacheWrite: 1.4)
        }
        if key.contains("kimi") && (key.contains("k3") || key.contains("k-3")) {
            return ModelTokenRate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3)
        }
        if key.contains("kimi") {
            return ModelTokenRate(input: 0.95, output: 4, cacheRead: 0.19, cacheWrite: 0.95)
        }
        return nil
    }

    private static func grokDisplayName(version: String, key: String) -> String {
        var parts = ["Grok", version]
        if key.contains("fast") {
            parts.append("Fast")
        }
        if let effort = thinkingEffort(in: key) {
            parts.append(effort)
        }
        return parts.joined(separator: " ")
    }

    private static func thinkingEffort(in key: String) -> String? {
        if key.contains("xhigh") || key.contains("x-high") || key.contains("extra-high") {
            return "xHigh"
        }
        if key.contains("high") { return "High" }
        if key.contains("medium") { return "Medium" }
        if key.contains("low") { return "Low" }
        return nil
    }

    private static func normalize(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func matches(_ key: String, _ needles: [String]) -> Bool {
        needles.contains { key.contains($0) }
    }
}
