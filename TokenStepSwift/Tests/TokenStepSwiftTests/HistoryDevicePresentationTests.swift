import Foundation
import XCTest
@testable import TokenStepSwift

final class HistoryDevicePresentationTests: XCTestCase {
    func testMergedDailyAddsPerMachineTokensWithoutDroppingIdentityInputs() {
        let air = ledger("air", name: "Air", local: true, days: [
            day("2026-08-17", tokens: 100, tool: "Codex"),
            day("2026-08-18", tokens: 40, tool: "Cursor")
        ])
        let mini = ledger("mini", name: "Mini", local: false, days: [
            day("2026-08-18", tokens: 60, tool: "Codex"),
            day("2026-08-19", tokens: 25, tool: "Grok")
        ])

        let merged = HistoryDevicePresentation.mergedDaily(from: [air, mini])
        XCTAssertEqual(merged.map(\.date), ["2026-08-17", "2026-08-18", "2026-08-19"])
        XCTAssertEqual(merged.first { $0.date == "2026-08-18" }?.totalTokens, 100)
        XCTAssertEqual(merged.first { $0.date == "2026-08-18" }?.tools["Codex"], 60)
        XCTAssertEqual(merged.first { $0.date == "2026-08-18" }?.tools["Cursor"], 40)
    }

    func testFilterKeepsOnlySelectedMachineHistory() {
        let air = ledger("air", name: "Air", local: true, days: [day("2026-08-18", tokens: 80, tool: "Codex")])
        let mini = ledger("mini", name: "Mini", local: false, days: [day("2026-08-18", tokens: 20, tool: "Cursor")])

        let filtered = HistoryDevicePresentation.filteredDaily(machines: [air, mini], filter: .machine("mini"))
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.totalTokens, 20)
        XCTAssertEqual(filtered.first?.tools["Cursor"], 20)
        XCTAssertNil(filtered.first?.tools["Codex"])
    }

    func testDeviceBarsStackBothMachinesOnTheSameDay() {
        let air = ledger("air", name: "Air", local: true, days: [day("2026-08-18", tokens: 80, tool: "Codex")])
        let mini = ledger("mini", name: "Mini", local: false, days: [day("2026-08-18", tokens: 20, tool: "Cursor")])
        let now = DateFormatter.tokenStepDay.date(from: "2026-08-18")!

        let bars = HistoryDevicePresentation.deviceBars(
            machines: [air, mini],
            filter: .all,
            lastDays: 2,
            now: now
        )
        XCTAssertEqual(bars.map(\.date), ["2026-08-17", "2026-08-18"])
        let today = bars.first { $0.date == "2026-08-18" }
        XCTAssertEqual(today?.totalTokens, 100)
        XCTAssertEqual(today?.slices.map(\.machineId).sorted(), ["air", "mini"])
        XCTAssertEqual(today?.slices.first { $0.machineId == "air" }?.tokens, 80)
        XCTAssertEqual(today?.slices.first { $0.machineId == "mini" }?.tokens, 20)
    }

    func testDeviceStatsAndToolBreakdownFollowTheFilter() {
        let air = ledger("air", name: "Air", local: true, days: [day("2026-08-18", tokens: 80, tool: "Codex")])
        let mini = ledger("mini", name: "Mini", local: false, days: [day("2026-08-18", tokens: 20, tool: "Cursor")])

        let allStats = HistoryDevicePresentation.deviceStats(from: [air, mini])
        XCTAssertEqual(allStats.map(\.machineId), ["air", "mini"])
        XCTAssertEqual(allStats.first?.percent ?? 0, 80, accuracy: 0.01)

        let filteredDaily = HistoryDevicePresentation.filteredDaily(machines: [air, mini], filter: .machine("mini"))
        let tools = HistoryDevicePresentation.toolUsages(from: filteredDaily)
        XCTAssertEqual(tools.map(\.tool), ["Cursor"])
        XCTAssertEqual(tools.first?.tokens, 20)
    }

    func testLocalMachineUsesSentinelColorIndex() {
        XCTAssertEqual(HistoryDevicePresentation.colorIndex(for: "air", isLocal: true), -1)
        XCTAssertGreaterThanOrEqual(HistoryDevicePresentation.colorIndex(for: "mini", isLocal: false), 0)
        XCTAssertEqual(
            HistoryDevicePresentation.colorIndex(for: "mini", isLocal: false),
            HistoryDevicePresentation.colorIndex(for: "mini", isLocal: false)
        )
    }

    private func ledger(_ id: String, name: String, local: Bool, days: [DailyUsage]) -> SyncedMachineLedger {
        SyncedMachineLedger(
            machineId: id,
            machineName: name,
            fileSlug: id,
            isLocal: local,
            daily: days
        )
    }

    private func day(_ date: String, tokens: Int, tool: String) -> DailyUsage {
        DailyUsage(
            date: date,
            tools: [tool: tokens],
            models: ["gpt": tokens],
            totalTokens: tokens,
            cost: Double(tokens) / 1_000_000
        )
    }
}
