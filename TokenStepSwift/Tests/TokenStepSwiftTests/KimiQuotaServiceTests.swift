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

    func testParsesOmittedCodeRatioAsZeroWhenEnabled() {
        let payload: [String: Any] = [
            "subscriptionBalance": [
                "amountUsedRatio": 0.1,
                "expireTime": "2026-09-01T00:00:00.000Z"
            ],
            "ratelimitCode5h": [
                "enabled": true
            ],
            "ratelimitCode7d": [
                "enabled": true,
                "ratio": 0
            ]
        ]
        let windows = KimiQuotaService.windows(from: payload)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[1].kind, .fiveHour)
        XCTAssertEqual(windows[1].usedPercent, 0, accuracy: 0.01)
        XCTAssertEqual(windows[2].kind, .sevenDay)
        XCTAssertEqual(windows[2].usedPercent, 0, accuracy: 0.01)
    }

    func testRejectsRefreshJWTAndAcceptsAccessJWT() {
        XCTAssertTrue(KimiWebAuth.isAccessToken(Self.jwt(typ: "access", expOffset: 3600)))
        XCTAssertFalse(KimiWebAuth.isAccessToken(Self.jwt(typ: "refresh", expOffset: 3600)))
        XCTAssertTrue(KimiWebAuth.isFresh(Self.jwt(typ: "access", expOffset: 3600)))
        XCTAssertFalse(KimiWebAuth.isFresh(Self.jwt(typ: "refresh", expOffset: 8_000_000)))
        XCTAssertFalse(KimiWebAuth.isFresh(Self.jwt(typ: "access", expOffset: -60)))
    }

    func testUnauthorizedDetectionFollowsHTTPStatus() {
        XCTAssertTrue(KimiQuotaService.isUnauthorized(TokenStepError.message("HTTP 401")))
        XCTAssertTrue(KimiQuotaService.isUnauthorized(TokenStepError.message("HTTP 403")))
        XCTAssertFalse(KimiQuotaService.isUnauthorized(TokenStepError.message("请求超时")))
        XCTAssertFalse(KimiQuotaService.isUnauthorized(TokenStepError.message("Kimi 额度暂不可用")))
    }

    func testStaleKimiWindowsStillDisplay() {
        let stale = ProviderQuota(
            provider: .kimi,
            windows: [
                QuotaWindow(kind: .monthlyCredits, usedPercent: 86.5, remaining: 13.5, total: 100, title: "总使用量")
            ],
            status: .available,
            fetchedAt: Date(timeIntervalSince1970: 0),
            metrics: QuotaMetrics(kimiMembershipUsed: 86.5)
        )
        XCTAssertTrue(stale.shouldDisplay)
        XCTAssertTrue(stale.isAvailable)

        let loggedOut = ProviderQuota.unavailable(.kimi, status: .notLoggedIn, message: "未登录 Kimi")
        XCTAssertFalse(loggedOut.shouldDisplay)
        XCTAssertFalse(loggedOut.isAvailable)
    }

    private static func jwt(typ: String, expOffset: TimeInterval) -> String {
        let payload: [String: Any] = [
            "typ": typ,
            "exp": Date().timeIntervalSince1970 + expOffset
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        var encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while encoded.last == "=" {
            encoded.removeLast()
        }
        return "eyJhbGciOiJIUzI1NiJ9.\(encoded).sig"
    }
}
