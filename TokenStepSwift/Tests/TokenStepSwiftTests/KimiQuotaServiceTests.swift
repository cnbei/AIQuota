import Foundation
import XCTest
@testable import TokenStepSwift

final class KimiQuotaServiceTests: XCTestCase {
    func testParsesMembershipStatsLikeAIQuota() {
        let payload: [String: Any] = [
            "subscriptionBalance": [
                "amountUsedRatio": 0.3575,
                "expireTime": "2026-09-01T00:00:00.000Z"
            ],
            "ratelimitCode5h": [
                "enabled": true,
                "ratio": 0.1
            ],
            "ratelimitCode7d": [
                "enabled": true,
                "ratio": 0.2
            ]
        ]
        let windows = KimiQuotaService.windows(from: payload)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].kind, .monthlyCredits)
        XCTAssertEqual(windows[0].usedPercent, 35.75, accuracy: 0.01)
        XCTAssertEqual(windows[1].kind, .fiveHour)
        XCTAssertEqual(windows[1].usedPercent, 10, accuracy: 0.01)
        XCTAssertEqual(windows[2].kind, .sevenDay)
        XCTAssertEqual(windows[2].usedPercent, 20, accuracy: 0.01)
    }
}
