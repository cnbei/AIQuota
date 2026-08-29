import XCTest
@testable import TokenStepSwift

final class UsageHistoryLedgerTests: XCTestCase {
    func testKeepsArchivedDayWhenLiveCollectionDropsIt() {
        let previous = snapshot(days: [
            day("2026-07-01", tools: ["Claude Code": 20_000_000]),
            day("2026-08-01", tools: ["Codex": 10_000_000])
        ])
        let collected = snapshot(days: [
            day("2026-08-01", tools: ["Codex": 12_000_000])
        ])

        let merged = UsageHistoryLedger.merge(collected: collected, previous: previous, now: date("2026-08-21"))

        XCTAssertEqual(merged.daily.map(\.date), ["2026-07-01", "2026-08-01"])
        XCTAssertEqual(merged.daily.first { $0.date == "2026-07-01" }?.totalTokens, 20_000_000)
        XCTAssertEqual(merged.daily.first { $0.date == "2026-08-01" }?.tools["Codex"], 12_000_000)
        XCTAssertEqual(merged.totals.tokens, 32_000_000)
        XCTAssertEqual(merged.totals.activeDays, 2)
    }

    func testKeepsDeletedToolOnADayStillSeenByAnotherSource() {
        let previous = snapshot(days: [
            day("2026-08-10", tools: ["Codex": 8_000_000, "Claude Code": 5_000_000])
        ])
        let collected = snapshot(days: [
            day("2026-08-10", tools: ["Codex": 9_000_000])
        ])

        let merged = UsageHistoryLedger.merge(collected: collected, previous: previous, now: date("2026-08-21"))
        let day = merged.daily.first { $0.date == "2026-08-10" }

        XCTAssertEqual(day?.tools["Codex"], 9_000_000)
        XCTAssertEqual(day?.tools["Claude Code"], 5_000_000)
        XCTAssertEqual(day?.totalTokens, 14_000_000)
    }

    func testKeepsDaysOlderThanFormerRetentionWindow() {
        let previous = snapshot(days: [
            day("2025-01-01", tools: ["Codex": 1_000_000]),
            day("2026-08-01", tools: ["Codex": 2_000_000])
        ])
        let collected = snapshot(days: [])

        let merged = UsageHistoryLedger.merge(collected: collected, previous: previous, now: date("2026-08-21"))

        XCTAssertEqual(merged.daily.map(\.date), ["2025-01-01", "2026-08-01"])
        XCTAssertEqual(merged.totals.tokens, 3_000_000)
    }

    func testKeepsHigherStoredToolWhenLiveReportsLess() {
        let previous = snapshot(days: [
            day("2026-08-10", tools: ["Codex": 10_000_000])
        ])
        let collected = snapshot(days: [
            day("2026-08-10", tools: ["Codex": 8_000_000])
        ])

        let merged = UsageHistoryLedger.merge(collected: collected, previous: previous, now: date("2026-08-21"))
        let day = merged.daily.first { $0.date == "2026-08-10" }

        XCTAssertEqual(day?.tools["Codex"], 10_000_000)
        XCTAssertEqual(day?.totalTokens, 10_000_000)
        XCTAssertEqual(merged.totals.tokens, 10_000_000)
    }

    func testPreservesRhythmWhenLiveDayDisappears() {
        let previous = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 1, cost: 0, activeDays: 1),
            daily: [day("2026-08-01", tools: ["Codex": 3_000_000])],
            rhythms: [
                DailyRhythm(
                    date: "2026-08-01",
                    buckets: [HourlyTokenBucket(hour: 10, tokens: 3_000_000)],
                    totalTokens: 3_000_000,
                    peakHour: 10,
                    peakTokens: 3_000_000,
                    activeHours: 1,
                    firstActiveHour: 10,
                    lastActiveHour: 10,
                    primaryTag: .oneShot,
                    companionTag: .quietDay
                )
            ],
            agentWork: [],
            tools: [],
            models: [],
            sources: [:]
        )
        let collected = snapshot(days: [])
        let merged = UsageHistoryLedger.merge(collected: collected, previous: previous, now: date("2026-08-21"))
        XCTAssertEqual(merged.rhythms.first?.date, "2026-08-01")
        XCTAssertEqual(merged.rhythms.first?.totalTokens, 3_000_000)
    }

    private func snapshot(days: [DailyUsage]) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: "2026-08-21T00:00:00Z",
            timezone: "Asia/Shanghai",
            totals: UsageTotals(
                tokens: days.map(\.totalTokens).reduce(0, +),
                cost: 0,
                activeDays: days.count
            ),
            daily: days,
            rhythms: [],
            agentWork: [],
            tools: [],
            models: [],
            sources: ["Codex": SourceInfo(status: "ok", files: 1, records: 1)]
        )
    }

    private func day(_ date: String, tools: [String: Int]) -> DailyUsage {
        DailyUsage(
            date: date,
            tools: tools,
            models: [:],
            modelsByTool: [:],
            totalTokens: tools.values.reduce(0, +),
            cost: 0
        )
    }

    private func date(_ value: String) -> Date {
        DateFormatter.tokenStepDay.date(from: value)!
    }
}

final class GoalStreakTests: XCTestCase {
    func testCurrentIncludesTodayWhenGoalIsMet() {
        let streak = GoalStreak.compute(
            daily: [
                day("2026-08-19", 100),
                day("2026-08-20", 100),
                day("2026-08-21", 100)
            ],
            goal: 100,
            today: "2026-08-21"
        )
        XCTAssertTrue(streak.todayReached)
        XCTAssertEqual(streak.current, 3)
        XCTAssertEqual(streak.longest, 3)
    }

    func testCurrentUsesYesterdayWhenTodayIsStillBelowGoal() {
        let streak = GoalStreak.compute(
            daily: [
                day("2026-08-19", 100),
                day("2026-08-20", 100),
                day("2026-08-21", 20)
            ],
            goal: 100,
            today: "2026-08-21"
        )
        XCTAssertFalse(streak.todayReached)
        XCTAssertEqual(streak.current, 2)
        XCTAssertEqual(streak.longest, 2)
        XCTAssertTrue(streak.popoverHeadline.contains("2"))
    }

    func testGapBreaksCurrentButKeepsLongest() {
        let streak = GoalStreak.compute(
            daily: [
                day("2026-08-16", 100),
                day("2026-08-17", 100),
                day("2026-08-18", 100),
                day("2026-08-20", 100),
                day("2026-08-21", 100)
            ],
            goal: 100,
            today: "2026-08-21"
        )
        XCTAssertEqual(streak.current, 2)
        XCTAssertEqual(streak.longest, 3)
    }

    private func day(_ date: String, _ tokens: Int) -> DailyUsage {
        DailyUsage(date: date, tools: ["Codex": tokens], totalTokens: tokens, cost: 0)
    }
}
