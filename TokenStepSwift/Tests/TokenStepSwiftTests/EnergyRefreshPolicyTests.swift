import Foundation
import XCTest
@testable import TokenStepSwift

final class EnergyRefreshPolicyTests: XCTestCase {
    func testBackgroundRefreshUsesFifteenMinuteFloorOnACPower() {
        XCTAssertEqual(
            EnergyRefreshPolicy.backgroundInterval(
                requestedSeconds: 300,
                powerSource: .ac,
                lowPowerMode: false
            ),
            900
        )
    }

    func testBackgroundRefreshUsesThirtyMinuteFloorOnBatteryOrLowPowerMode() {
        XCTAssertEqual(
            EnergyRefreshPolicy.backgroundInterval(
                requestedSeconds: 300,
                powerSource: .battery,
                lowPowerMode: false
            ),
            1_800
        )
        XCTAssertEqual(
            EnergyRefreshPolicy.backgroundInterval(
                requestedSeconds: 300,
                powerSource: .ac,
                lowPowerMode: true
            ),
            1_800
        )
    }

    func testManualModeDoesNotScheduleBackgroundRefresh() {
        XCTAssertNil(
            EnergyRefreshPolicy.backgroundInterval(
                requestedSeconds: 0,
                powerSource: .battery,
                lowPowerMode: true
            )
        )
    }

    func testForegroundRefreshStillHonorsRequestedFreshness() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(
            EnergyRefreshPolicy.shouldRefreshForForeground(
                generatedAt: now.addingTimeInterval(-301),
                requestedSeconds: 300,
                now: now
            )
        )
        XCTAssertFalse(
            EnergyRefreshPolicy.shouldRefreshForForeground(
                generatedAt: now.addingTimeInterval(-299),
                requestedSeconds: 300,
                now: now
            )
        )
    }

    func testIndependentTTLUsesLastAttemptRatherThanUsageRefresh() {
        let now = Date(timeIntervalSince1970: 20_000)
        XCTAssertTrue(
            EnergyRefreshPolicy.isFresh(
                lastAttemptAt: now.addingTimeInterval(-899),
                ttl: 900,
                now: now
            )
        )
        XCTAssertFalse(
            EnergyRefreshPolicy.isFresh(
                lastAttemptAt: now.addingTimeInterval(-900),
                ttl: 900,
                now: now
            )
        )
    }

    func testAutomaticFailureBackoffAndVisibleTickAreBounded() {
        XCTAssertEqual(EnergyRefreshPolicy.automaticRetryTTL(requestedSeconds: 300), 300)
        XCTAssertEqual(EnergyRefreshPolicy.automaticRetryTTL(requestedSeconds: 0), 60)
        XCTAssertEqual(EnergyRefreshPolicy.foregroundTickInterval(requestedSeconds: 300), 60)
        XCTAssertEqual(EnergyRefreshPolicy.foregroundTickInterval(requestedSeconds: 30), 30)
        XCTAssertNil(EnergyRefreshPolicy.foregroundTickInterval(requestedSeconds: 0))
    }

    func testSourceChangeUsesFifteenSecondFloorOnACPower() {
        XCTAssertEqual(
            EnergyRefreshPolicy.sourceChangeFloorSeconds(
                powerSource: .ac,
                lowPowerMode: false
            ),
            15
        )
    }

    func testSourceChangeUsesThirtySecondFloorOnBatteryOrLowPowerMode() {
        XCTAssertEqual(
            EnergyRefreshPolicy.sourceChangeFloorSeconds(
                powerSource: .battery,
                lowPowerMode: false
            ),
            30
        )
        XCTAssertEqual(
            EnergyRefreshPolicy.sourceChangeFloorSeconds(
                powerSource: .ac,
                lowPowerMode: true
            ),
            30
        )
    }

    func testSourceChangeRefreshHonorsPowerAwareFloor() {
        let now = Date(timeIntervalSince1970: 30_000)
        XCTAssertTrue(
            EnergyRefreshPolicy.shouldRefreshForSourceChange(
                lastAttemptAt: nil,
                powerSource: .ac,
                lowPowerMode: false,
                now: now
            )
        )
        XCTAssertFalse(
            EnergyRefreshPolicy.shouldRefreshForSourceChange(
                lastAttemptAt: now.addingTimeInterval(-14),
                powerSource: .ac,
                lowPowerMode: false,
                now: now
            )
        )
        XCTAssertTrue(
            EnergyRefreshPolicy.shouldRefreshForSourceChange(
                lastAttemptAt: now.addingTimeInterval(-15),
                powerSource: .ac,
                lowPowerMode: false,
                now: now
            )
        )
        XCTAssertFalse(
            EnergyRefreshPolicy.shouldRefreshForSourceChange(
                lastAttemptAt: now.addingTimeInterval(-29),
                powerSource: .battery,
                lowPowerMode: false,
                now: now
            )
        )
        XCTAssertTrue(
            EnergyRefreshPolicy.shouldRefreshForSourceChange(
                lastAttemptAt: now.addingTimeInterval(-30),
                powerSource: .battery,
                lowPowerMode: false,
                now: now
            )
        )
    }

    func testSourceChangeRetryDelayLeavesATrailingCollect() {
        let now = Date(timeIntervalSince1970: 40_000)
        XCTAssertNil(
            EnergyRefreshPolicy.sourceChangeRetryDelay(
                lastAttemptAt: nil,
                powerSource: .ac,
                lowPowerMode: false,
                now: now
            )
        )
        XCTAssertEqual(
            EnergyRefreshPolicy.sourceChangeRetryDelay(
                lastAttemptAt: now.addingTimeInterval(-10),
                powerSource: .ac,
                lowPowerMode: false,
                now: now
            ),
            5
        )
        XCTAssertNil(
            EnergyRefreshPolicy.sourceChangeRetryDelay(
                lastAttemptAt: now.addingTimeInterval(-15),
                powerSource: .ac,
                lowPowerMode: false,
                now: now
            )
        )
    }
}
