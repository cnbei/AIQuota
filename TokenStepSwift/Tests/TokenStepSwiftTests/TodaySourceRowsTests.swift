import XCTest
@testable import TokenStepSwift

final class TodaySourceRowsTests: XCTestCase {
    func testGroupsOverflowSources() {
        let rows = TodaySourceRows.make(
            tools: [
                "Codex": 62,
                "Claude Code": 21,
                "ZCode": 9,
                "Hermes Agent": 5,
                "WorkBuddy": 3
            ],
            maxNamed: 3
        )

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].name, "Codex")
        XCTAssertEqual(rows[1].name, "Claude Code")
        XCTAssertEqual(rows[2].name, "ZCode")
        XCTAssertEqual(rows[3].tokens, 8)
        XCTAssertTrue(rows[3].name.contains("2"))
    }

    func testEmptyToolsReturnsNoRows() {
        XCTAssertTrue(TodaySourceRows.make(tools: [:]).isEmpty)
    }

    func testNestsModelsUnderEachClientWithUSDAndTokens() {
        let rows = TodaySourceRows.make(
            tools: [
                "Codex": 1_910_000,
                "Cursor": 33_840_000
            ],
            modelsByTool: [
                "Codex": ["gpt-5.4": 1_910_000],
                "Cursor": [
                    "claude-fable-5-thinking-high": 12_000_000,
                    "grok-4.6": 21_840_000
                ]
            ],
            modelCosts: [
                "gpt-5.4": 1.20,
                "claude-fable-5-thinking-high": 38.10,
                "grok-4.6": 4.20
            ],
            toolCosts: [
                "Codex": 1.20,
                "Cursor": 42.30
            ]
        )

        XCTAssertEqual(rows.map(\.name), ["Codex", "Cursor"])
        XCTAssertEqual(rows[0].cost, 1.20, accuracy: 0.0001)
        XCTAssertEqual(rows[0].models.map(\.name), ["GPT-5.4"])
        XCTAssertEqual(rows[0].models[0].tokens, 1_910_000)
        XCTAssertEqual(rows[0].models[0].cost, 1.20, accuracy: 0.0001)

        XCTAssertEqual(rows[1].cost, 42.30, accuracy: 0.0001)
        XCTAssertEqual(rows[1].models.map(\.name), ["Fable 5", "Grok 4.6"])
        XCTAssertEqual(rows[1].models[0].cost, 38.10, accuracy: 0.0001)
        XCTAssertEqual(rows[1].models[1].tokens, 21_840_000)
    }

    func testInfersCursorModelsWhenToolMapIsMissing() {
        let rows = TodaySourceRows.make(
            tools: ["Codex": 100, "Cursor": 200],
            models: [
                "gpt-5.4": 100,
                "grok-4.6": 120,
                "claude-fable-5": 80
            ]
        )
        let cursor = rows.first { $0.name == "Cursor" }
        XCTAssertEqual(cursor?.models.map(\.name), ["Fable 5", "Grok 4.6"])
    }

    func testModelCostRowsRankFableAboveGrokForTheSameTokens() {
        let rows = TodayModelCostRows.make(
            models: [
                "claude-fable-5-thinking-high": 1_200_000,
                "grok-4.6": 1_200_000
            ],
            modelCosts: [
                "claude-fable-5-thinking-high": 3.0,
                "grok-4.6": 0.52
            ]
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Fable 5")
        XCTAssertEqual(rows[0].cost, 3.0, accuracy: 0.0001)
        XCTAssertEqual(rows[1].name, "Grok 4.6")
        XCTAssertEqual(rows[1].cost, 0.52, accuracy: 0.0001)
        XCTAssertEqual(rows[0].percent + rows[1].percent, 100, accuracy: 0.01)
    }

    func testCursorGrokFastVariantsStayDistinctRows() {
        let rows = TodaySourceRows.make(
            tools: ["Cursor": 90_000_000],
            modelsByTool: [
                "Cursor": [
                    "cursor-grok-4.6-xhigh-fast": 73_700_000,
                    "cursor-grok-4.6-high-fast": 16_580_000
                ]
            ]
        )
        let names = rows.first?.models.map(\.name) ?? []
        let ids = rows.first?.models.map(\.id) ?? []
        XCTAssertEqual(names, ["Grok 4.6 Fast xHigh", "Grok 4.6 Fast High"])
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(rows.first?.models.map(\.tokens), [73_700_000, 16_580_000])
    }

    func testModelCostRowsEstimateFromListPriceWhenCostsAreMissing() {
        let rows = TodayModelCostRows.make(
            models: ["grok-4.6": 1_000_000],
            modelCosts: [:]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].cost, 2.0, accuracy: 0.0001)
    }
}
