import Foundation
import XCTest
@testable import TokenStepSwift

final class QuotaPresentationTests: XCTestCase {
    func testCursorIncludedModeFollowsSpendPool() {
        let quota = cursorQuota(
            included: 10,
            models: 40,
            other: 80,
            spend: 2.4,
            limit: 20
        )
        XCTAssertEqual(
            QuotaPresentation.remainingPercent(quota, cursorMode: .included, kimiMode: .membership),
            90,
            accuracy: 0.01
        )
        let detail = QuotaPresentation.detail(quota, cursorMode: .included, kimiMode: .membership)
        XCTAssertTrue(detail.contains("$2.40"))
        XCTAssertTrue(detail.contains("总体"))
        XCTAssertTrue(detail.contains("Cursor Models"))
        XCTAssertTrue(detail.contains("Other Models"))
    }

    func testCursorModelsModeSwitchesRingWithoutRefetch() {
        let quota = cursorQuota(included: 10, models: 40, other: 80)
        XCTAssertEqual(
            QuotaPresentation.remainingPercent(quota, cursorMode: .cursorModels, kimiMode: .membership),
            60,
            accuracy: 0.01
        )
        XCTAssertEqual(
            QuotaPresentation.remainingPercent(quota, cursorMode: .otherModels, kimiMode: .membership),
            20,
            accuracy: 0.01
        )
    }

    func testKimiCodeModeUsesTightestCodeWindow() {
        let quota = ProviderQuota(
            provider: .kimi,
            windows: [
                QuotaWindow(kind: .monthlyCredits, usedPercent: 86.4, remaining: 13.6, total: 100, title: "总使用量"),
                QuotaWindow(kind: .fiveHour, usedPercent: 0, remaining: 100, total: 100, title: "Code"),
                QuotaWindow(kind: .sevenDay, usedPercent: 2.6, remaining: 97.4, total: 100, title: "Code")
            ],
            status: .available,
            fetchedAt: Date(),
            metrics: QuotaMetrics(kimiMembershipUsed: 86.4, kimiCodeUsed: 2.6)
        )
        XCTAssertEqual(
            QuotaPresentation.remainingPercent(quota, cursorMode: .included, kimiMode: .membership),
            13.6,
            accuracy: 0.01
        )
        XCTAssertEqual(
            QuotaPresentation.remainingPercent(quota, cursorMode: .included, kimiMode: .code),
            97.4,
            accuracy: 0.01
        )
        let codeDetail = QuotaPresentation.detail(quota, cursorMode: .included, kimiMode: .code)
        XCTAssertTrue(codeDetail.contains("5h"))
        XCTAssertTrue(codeDetail.contains("7d"))
    }

    func testResetRelativeFormat() {
        let now = Date()
        XCTAssertEqual(QuotaResetFormat.relative(now.addingTimeInterval(-10), now: now), "已重置")
        XCTAssertEqual(QuotaResetFormat.relative(now.addingTimeInterval(90 * 60), now: now), "1h 30m")
        XCTAssertEqual(QuotaResetFormat.relative(now.addingTimeInterval(26 * 3600), now: now), "1d 2h")
    }

    func testWindowsWithSameKindStayIdentifiable() {
        let windows = [
            QuotaWindow(kind: .weekly, usedPercent: 2, title: "本周共用"),
            QuotaWindow(kind: .weekly, usedPercent: 1, title: "Grok Build")
        ]
        XCTAssertEqual(Set(windows.map(\.id)).count, 2)
    }

    func testGrokDisplayWindowsKeepSharedPoolOnly() {
        let quota = ProviderQuota(
            provider: .grok,
            windows: [
                QuotaWindow(kind: .weekly, usedPercent: 2, remaining: 98, total: 100, title: "本周共用"),
                QuotaWindow(kind: .weekly, usedPercent: 1.5, remaining: 98.5, total: 100, title: "Grok Build"),
                QuotaWindow(kind: .weekly, usedPercent: 0.4, remaining: 99.6, total: 100, title: "Imagine")
            ],
            status: .available,
            fetchedAt: Date(),
            metrics: QuotaMetrics(grokWeeklyUsed: 2)
        )
        XCTAssertEqual(quota.grokDisplayWindows.count, 1)
        XCTAssertEqual(quota.grokDisplayWindows.first?.title, "本周共用")
        XCTAssertEqual(
            QuotaPresentation.remainingPercent(quota, cursorMode: .cursorModels, kimiMode: .membership),
            98,
            accuracy: 0.01
        )
    }
}

private func cursorQuota(
    included: Double,
    models: Double,
    other: Double,
    spend: Double? = nil,
    limit: Double? = nil
) -> ProviderQuota {
    ProviderQuota(
        provider: .cursor,
        windows: [
            QuotaWindow(kind: .monthlyCredits, usedPercent: included, remaining: 100 - included, total: 100, title: "总体"),
            QuotaWindow(kind: .cursorModels, usedPercent: models, remaining: 100 - models, total: 100),
            QuotaWindow(kind: .otherModels, usedPercent: other, remaining: 100 - other, total: 100)
        ],
        status: .available,
        fetchedAt: Date(),
        metrics: QuotaMetrics(
            cursorIncludedUsed: included,
            cursorModelsUsed: models,
            otherModelsUsed: other,
            cursorSpendDollars: spend,
            cursorLimitDollars: limit
        )
    )
}
