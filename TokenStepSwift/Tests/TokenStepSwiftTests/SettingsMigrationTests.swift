import Foundation
import XCTest
@testable import TokenStepSwift

final class SettingsMigrationTests: XCTestCase {
    func testLegacyShowCodexQuotaTrueMigratesToCodexAndClaude() throws {
        let json = """
        {"show_codex_quota": true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(TokenStepSettings.self, from: json)
        XCTAssertEqual(settings.enabledQuotaProviders, [.codex, .claude])
        XCTAssertTrue(settings.showCodexQuota)
        XCTAssertFalse(settings.cursorQuotaEnabled)
        XCTAssertFalse(settings.cursorCodeSignalEnabled)
    }

    func testLegacyShowCodexQuotaFalseMigratesToEmptySet() throws {
        let json = """
        {"show_codex_quota": false}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(TokenStepSettings.self, from: json)
        XCTAssertTrue(settings.enabledQuotaProviders.isEmpty)
        XCTAssertFalse(settings.showCodexQuota)
    }

    func testRoundTripKeepsNewFields() throws {
        var settings = TokenStepSettings.defaults
        settings.enabledQuotaProviders = [.codex, .cursor, .glm]
        settings.cursorQuotaEnabled = true
        settings.cursorCodeSignalEnabled = true
        settings.historyDays = 90
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TokenStepSettings.self, from: data)
        XCTAssertEqual(decoded.enabledQuotaProviders, [.codex, .cursor, .glm])
        XCTAssertTrue(decoded.cursorQuotaEnabled)
        XCTAssertTrue(decoded.cursorCodeSignalEnabled)
        XCTAssertEqual(decoded.historyDays, 90)
        XCTAssertTrue(decoded.showCodexQuota)
        XCTAssertEqual(decoded.cursorDisplayMode, .cursorModels)
        XCTAssertEqual(decoded.kimiDisplayMode, .membership)
        XCTAssertEqual(decoded.menuBarRingMode, .quotaRemaining)
        XCTAssertEqual(decoded.usageExportFolder, "")
        XCTAssertFalse(decoded.usageExportAutoEnabled)
        XCTAssertTrue(decoded.subscriptionPlans.isEmpty)
    }

    func testRoundTripKeepsQuotaDisplayPreferences() throws {
        var settings = TokenStepSettings.defaults
        settings.selectedQuotaProvider = .kimi
        settings.cursorDisplayMode = .otherModels
        settings.kimiDisplayMode = .code
        settings.menuBarRingMode = .quotaRemaining
        let decoded = try JSONDecoder().decode(TokenStepSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.selectedQuotaProvider, .kimi)
        XCTAssertEqual(decoded.cursorDisplayMode, .otherModels)
        XCTAssertEqual(decoded.kimiDisplayMode, .code)
        XCTAssertEqual(decoded.menuBarRingMode, .quotaRemaining)
    }

    func testCursorIncludedModeMigratesToCursorModels() throws {
        let json = """
        {"cursor_display_mode": "included"}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(TokenStepSettings.self, from: json)
        XCTAssertEqual(settings.cursorDisplayMode, .cursorModels)

        var roundTrip = TokenStepSettings.defaults
        roundTrip.cursorDisplayMode = .included
        let decoded = try JSONDecoder().decode(TokenStepSettings.self, from: JSONEncoder().encode(roundTrip))
        XCTAssertEqual(decoded.cursorDisplayMode, .cursorModels)
    }

    func testCursorFlagStaysInSyncWithProviderSet() {
        var settings = TokenStepSettings.defaults
        settings.setQuotaProvider(.cursor, enabled: true)
        XCTAssertTrue(settings.cursorQuotaEnabled)
        XCTAssertTrue(settings.enabledQuotaProviders.contains(.cursor))
        settings.setQuotaProvider(.cursor, enabled: false)
        XCTAssertFalse(settings.cursorQuotaEnabled)
        XCTAssertFalse(settings.enabledQuotaProviders.contains(.cursor))
    }

    func testRoundTripKeepsExportSettings() throws {
        var settings = TokenStepSettings.defaults
        settings.usageExportFolder = "/tmp/aiquota-export"
        settings.usageExportAutoEnabled = true
        let decoded = try JSONDecoder().decode(TokenStepSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.usageExportFolder, "/tmp/aiquota-export")
        XCTAssertTrue(decoded.usageExportAutoEnabled)
    }

    func testExportAutoRequiresFolder() throws {
        let json = """
        {"usage_export_auto_enabled": true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(TokenStepSettings.self, from: json)
        XCTAssertFalse(settings.usageExportAutoEnabled)
        XCTAssertEqual(settings.usageExportFolder, "")
    }

    func testRoundTripKeepsSubscriptionPlansAndTightestQuota() throws {
        var settings = TokenStepSettings.defaults
        settings.menuBarRingMode = .tightestQuota
        settings.upsertSubscription(provider: .cursor, monthlyPrice: 20, renewalDay: 12)
        settings.upsertSubscription(provider: .kimi, monthlyPrice: 0)
        let decoded = try JSONDecoder().decode(TokenStepSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.menuBarRingMode, .tightestQuota)
        XCTAssertEqual(decoded.subscriptionPlans.count, 1)
        XCTAssertEqual(decoded.subscriptionPlans.first?.provider, .cursor)
        XCTAssertEqual(decoded.subscriptionPlans.first?.monthlyPrice, 20)
        XCTAssertEqual(decoded.subscriptionPlans.first?.renewalDay, 12)
    }
}
