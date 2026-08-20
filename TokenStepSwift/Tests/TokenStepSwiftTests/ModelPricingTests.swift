import XCTest
@testable import TokenStepSwift

final class ModelPricingTests: XCTestCase {
    func testFable5IsSeveralTimesMoreExpensiveThanGrok46ForTheSameMix() {
        let fable = ModelPricing.cost(
            model: "claude-fable-5-thinking-high",
            inputTokens: 1_000_000,
            outputTokens: 200_000,
            cacheReadTokens: 400_000,
            cacheWriteTokens: 50_000
        )
        let grok = ModelPricing.cost(
            model: "grok-4.6",
            inputTokens: 1_000_000,
            outputTokens: 200_000,
            cacheReadTokens: 400_000,
            cacheWriteTokens: 50_000
        )

        XCTAssertEqual(fable, 21.025, accuracy: 0.0001)
        XCTAssertEqual(grok, 3.5, accuracy: 0.0001)
        XCTAssertGreaterThan(fable, grok * 5)
    }

    func testCursorModelAliasesUseTheSameRate() {
        let named = ModelPricing.cost(model: "fable-5", inputTokens: 100_000, outputTokens: 20_000)
        let cursor = ModelPricing.cost(model: "claude-fable-5", inputTokens: 100_000, outputTokens: 20_000)
        XCTAssertEqual(named, cursor, accuracy: 0.0001)
        XCTAssertEqual(named, 2.0, accuracy: 0.0001)
    }

    func testGrokFastVariantIsDoubleTheStandardRate() {
        let standard = ModelPricing.cost(model: "grok-4.6", inputTokens: 1_000_000, outputTokens: 1_000_000)
        let fast = ModelPricing.cost(model: "grok-4.6-fast", inputTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(standard, 8.0, accuracy: 0.0001)
        XCTAssertEqual(fast, 16.0, accuracy: 0.0001)
    }

    func testUnknownModelFallsBackToOneDollarPerMillionTokens() {
        XCTAssertEqual(
            ModelPricing.cost(model: "mystery-bot", inputTokens: 0, outputTokens: 0, totalTokens: 2_000_000),
            2.0,
            accuracy: 0.0001
        )
    }
}
