import XCTest
@testable import TokenStepSwift

final class UsageHighWaterMergeTests: XCTestCase {
    func testDaysKeepOmittedDatesAndRaiseOnlyWhenIncomingIsHigher() {
        let stored = [
            day("2026-07-01", tools: ["Codex": 20]),
            day("2026-08-01", tools: ["Codex": 10, "Grok Build": 4])
        ]
        let incoming = [
            day("2026-08-01", tools: ["Codex": 8, "WorkBuddy": 3])
        ]

        let merged = UsageHighWaterMerge.days(stored, incoming)

        XCTAssertEqual(merged.map(\.date), ["2026-07-01", "2026-08-01"])
        XCTAssertEqual(merged.first { $0.date == "2026-07-01" }?.totalTokens, 20)
        XCTAssertEqual(merged.first { $0.date == "2026-08-01" }?.tools["Codex"], 10)
        XCTAssertEqual(merged.first { $0.date == "2026-08-01" }?.tools["Grok Build"], 4)
        XCTAssertEqual(merged.first { $0.date == "2026-08-01" }?.tools["WorkBuddy"], 3)
        XCTAssertEqual(UsageHighWaterMerge.totalTokens(merged), 37)
    }

    func testEmptyIncomingDoesNotEraseLifetimeDays() {
        let stored = [day("2026-03-28", tools: ["Codex": 50])]
        XCTAssertEqual(UsageHighWaterMerge.days(stored, []).first?.totalTokens, 50)
        XCTAssertFalse(UsageHighWaterMerge.isRicher([], than: stored))
        XCTAssertTrue(UsageHighWaterMerge.isRicher(stored, than: []))
    }

    func testCursorDaysKeepOmittedWindowDaysAndHighWater() {
        let existing = [
            cursorDay("2026-08-16", tokens: 4_000, events: 2),
            cursorDay("2026-08-17", tokens: 8_000, events: 4)
        ]
        let incoming = [
            cursorDay("2026-08-17", tokens: 3_000, events: 1),
            cursorDay("2026-08-18", tokens: 5_000, events: 3)
        ]

        let merged = CursorUsageService.mergeCursorDays(existing, incoming)
        XCTAssertEqual(merged.map(\.date), ["2026-08-16", "2026-08-17", "2026-08-18"])
        XCTAssertEqual(merged.first { $0.date == "2026-08-16" }?.totalTokens, 4_000)
        XCTAssertEqual(merged.first { $0.date == "2026-08-17" }?.totalTokens, 8_000)
        XCTAssertEqual(merged.first { $0.date == "2026-08-18" }?.totalTokens, 5_000)
    }

    private func day(_ date: String, tools: [String: Int]) -> DailyUsage {
        DailyUsage(date: date, tools: tools, totalTokens: tools.values.reduce(0, +), cost: 0)
    }

    private func cursorDay(_ date: String, tokens: Int, events: Int) -> CursorUsageDay {
        CursorUsageDay(
            date: date,
            totalTokens: tokens,
            inputTokens: tokens,
            cachedInputTokens: 0,
            outputTokens: 0,
            cacheWriteTokens: 0,
            cost: 0,
            eventCount: events,
            models: ["composer-1": tokens],
            hourlyBuckets: []
        )
    }
}
