import Foundation
import XCTest
@testable import TokenStepSwift

final class CodexQuotaServiceTests: XCTestCase {
    func testParsesChatGPTUsageWindowsLikeAIQuota() {
        let payload: [String: Any] = [
            "plan_type": "prolite",
            "rate_limit": [
                "primary_window": [
                    "limit_window_seconds": 18000,
                    "used_percent": 22,
                    "reset_at": 1_787_000_000
                ],
                "secondary_window": [
                    "limit_window_seconds": 604800,
                    "used_percent": 41,
                    "reset_at": 1_787_500_000
                ]
            ]
        ]
        let snapshot = CodexQuotaService.snapshot(fromUsageJSON: payload)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 22, accuracy: 0.01)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 41, accuracy: 0.01)
        XCTAssertTrue(snapshot.isAvailable)
    }
}
