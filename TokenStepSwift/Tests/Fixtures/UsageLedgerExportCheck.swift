#if TOKENSTEP_TESTING
import Foundation

@main
enum UsageLedgerExportCheck {
    static func main() throws {
        try testArchiveKeepsMissingDay()
        try testMergeKeepsDeletedTool()
        try testKeepsHigherStoredToolWhenLiveDrops()
        try testKeepsDaysOlderThanFormerRetentionWindow()
        try testStreakUsesYesterdayWhenTodayIsShort()
        try testExportOmitsIdentity()
        print("usage-ledger-export-check: ok")
    }

    private static func testArchiveKeepsMissingDay() throws {
        let previous = snapshot(days: [
            day("2026-07-01", ["Claude Code": 20_000_000]),
            day("2026-08-01", ["Codex": 10_000_000])
        ])
        let collected = snapshot(days: [
            day("2026-08-01", ["Codex": 12_000_000])
        ])
        let merged = UsageHistoryLedger.merge(
            collected: collected,
            previous: previous,
            now: UsageDayDate.formatter.date(from: "2026-08-21")!
        )
        guard merged.daily.map(\.date) == ["2026-07-01", "2026-08-01"] else {
            throw checkError("archived day dropped")
        }
        guard merged.daily.first(where: { $0.date == "2026-07-01" })?.totalTokens == 20_000_000 else {
            throw checkError("archived tokens lost")
        }
        guard merged.totals.tokens == 32_000_000 else {
            throw checkError("merged totals wrong")
        }
    }

    private static func testMergeKeepsDeletedTool() throws {
        let previous = snapshot(days: [
            day("2026-08-10", ["Codex": 8_000_000, "Claude Code": 5_000_000])
        ])
        let collected = snapshot(days: [
            day("2026-08-10", ["Codex": 9_000_000])
        ])
        let merged = UsageHistoryLedger.merge(
            collected: collected,
            previous: previous,
            now: UsageDayDate.formatter.date(from: "2026-08-21")!
        )
        let row = merged.daily.first { $0.date == "2026-08-10" }
        guard row?.tools["Codex"] == 9_000_000, row?.tools["Claude Code"] == 5_000_000 else {
            throw checkError("deleted tool was not preserved")
        }
    }

    private static func testKeepsHigherStoredToolWhenLiveDrops() throws {
        let previous = snapshot(days: [
            day("2026-08-10", ["Codex": 10_000_000])
        ])
        let collected = snapshot(days: [
            day("2026-08-10", ["Codex": 8_000_000])
        ])
        let merged = UsageHistoryLedger.merge(
            collected: collected,
            previous: previous,
            now: UsageDayDate.formatter.date(from: "2026-08-21")!
        )
        guard merged.daily.first(where: { $0.date == "2026-08-10" })?.totalTokens == 10_000_000 else {
            throw checkError("live collection was allowed to lower a stored day")
        }
    }

    private static func testKeepsDaysOlderThanFormerRetentionWindow() throws {
        let previous = snapshot(days: [
            day("2025-01-01", ["Codex": 1_000_000]),
            day("2026-08-01", ["Codex": 2_000_000])
        ])
        let merged = UsageHistoryLedger.merge(
            collected: snapshot(days: []),
            previous: previous,
            now: UsageDayDate.formatter.date(from: "2026-08-21")!
        )
        guard merged.daily.map(\.date) == ["2025-01-01", "2026-08-01"],
              merged.totals.tokens == 3_000_000
        else {
            throw checkError("lifetime day was dropped")
        }
    }

    private static func testStreakUsesYesterdayWhenTodayIsShort() throws {
        let streak = GoalStreak.compute(
            daily: [
                day("2026-08-19", ["Codex": 100]),
                day("2026-08-20", ["Codex": 100]),
                day("2026-08-21", ["Codex": 20])
            ],
            goal: 100,
            today: "2026-08-21"
        )
        guard streak.current == 2, streak.longest == 2, streak.todayReached == false else {
            throw checkError("streak calculation failed")
        }
    }

    private static func testExportOmitsIdentity() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiquota-export-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let snapshot = snapshot(days: [
            day("2026-08-21", ["Claude Code": 10])
        ])
        _ = try UsageExportService.export(
            snapshot: snapshot,
            to: folder,
            now: UsageDayDate.formatter.date(from: "2026-08-21")!
        )
        let json = try String(
            contentsOf: folder.appendingPathComponent(UsageExportService.jsonFileName),
            encoding: .utf8
        )
        guard json.contains("Claude Code"), !json.contains("email"), !json.contains("quota") else {
            throw checkError("export content was unsafe or incomplete")
        }
        let csv = try String(
            contentsOf: folder.appendingPathComponent(UsageExportService.dailyCSVFileName),
            encoding: .utf8
        )
        guard csv.contains("2026-08-21,Claude Code,10,") else {
            throw checkError("daily csv missing Claude Code row: \(csv)")
        }
    }

    private static func snapshot(days: [DailyUsage]) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: "2026-08-21T00:00:00Z",
            timezone: "Asia/Shanghai",
            totals: UsageTotals(
                tokens: days.map(\.totalTokens).reduce(0, +),
                cost: 0,
                activeDays: days.count
            ),
            daily: days,
            tools: [],
            models: [],
            sources: [:]
        )
    }

    private static func day(_ date: String, _ tools: [String: Int]) -> DailyUsage {
        DailyUsage(
            date: date,
            tools: tools,
            totalTokens: tools.values.reduce(0, +),
            cost: 0
        )
    }

    private static func checkError(_ message: String) -> NSError {
        NSError(domain: "UsageLedgerExportCheck", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }
}
#endif
