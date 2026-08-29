import Foundation
import XCTest
@testable import TokenStepSwift

final class GrokQuotaServiceTests: XCTestCase {
    func testReadsIssuerScopedKeyFromCurrentAuthJSON() {
        let payload: [String: Any] = [
            "https://auth.x.ai::client-id": [
                "key": "eyJhbGciOiJIUzI1NiJ9.payload.sig",
                "auth_mode": "oidc",
                "refresh_token": "refresh-token-value"
            ]
        ]
        XCTAssertEqual(
            GrokQuotaService.sessionToken(from: payload),
            "eyJhbGciOiJIUzI1NiJ9.payload.sig"
        )
    }

    func testParsesSharedWeeklyPoolWithoutProductBars() {
        let payload: [String: Any] = [
            "config": [
                "creditUsagePercent": 2,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-08-24T00:00:00.000Z"
                ],
                "productUsage": [
                    ["product": 2, "usagePercent": 1.5],
                    ["product": 5, "usagePercent": 0.4]
                ]
            ]
        ]
        let windows = GrokQuotaService.windows(from: payload)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.kind, .weekly)
        XCTAssertEqual(windows.first?.usedPercent, 2, accuracy: 0.01)

        let products = GrokQuotaService.productWindows(
            from: payload["config"] as? [String: Any] ?? [:],
            kind: .weekly,
            reset: nil
        )
        XCTAssertTrue(products.contains(where: { $0.title == "Grok Build" && abs($0.usedPercent - 1.5) < 0.01 }))
        XCTAssertTrue(products.contains(where: { $0.title == "Imagine" && abs($0.usedPercent - 0.4) < 0.01 }))
    }

    func testParsesOmittedCreditUsagePercentAsZeroWeeklyPool() {
        let payload: [String: Any] = [
            "config": [
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-08-24T00:00:00.000000000Z"
                ],
                "product_usage": [
                    ["product": 2, "usage_percent": 0]
                ]
            ]
        ]
        let windows = GrokQuotaService.windows(from: payload)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.kind, .weekly)
        XCTAssertEqual(windows.first?.usedPercent, 0, accuracy: 0.01)
        XCTAssertTrue(["本周共用", "Shared this week", "本週共用"].contains(windows.first?.title ?? ""))

        let metrics = GrokQuotaService.productMetrics(from: payload["config"] as? [String: Any] ?? [:])
        XCTAssertEqual(metrics.grokBuildUsed ?? -1, 0, accuracy: 0.01)
    }

    func testParsesWeeklyCreditsPercent() {
        let payload: [String: Any] = [
            "config": [
                "creditUsagePercent": 13,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-08-24T00:00:00.000Z"
                ]
            ]
        ]
        let windows = GrokQuotaService.windows(from: payload)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].kind, .weekly)
        XCTAssertEqual(windows[0].usedPercent, 13, accuracy: 0.01)
        XCTAssertEqual(windows[0].remainingPercent, 87, accuracy: 0.01)
    }

    func testIgnoresLegacyMonthlyLimitLedger() {
        XCTAssertTrue(
            GrokQuotaService.windows(from: [
                "config": [
                    "monthlyLimit": ["val": 1000],
                    "used": ["val": 0],
                    "prepaidBalance": ["val": 1000],
                    "billingPeriodEnd": "2026-09-01T00:00:00Z"
                ]
            ]).isEmpty
        )

        let mixed = GrokQuotaService.windows(from: [
            "config": [
                "creditUsagePercent": 45,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-08-30T17:25:26.231Z"
                ],
                "monthlyLimit": ["val": 1000],
                "used": ["val": 0],
                "billingPeriodEnd": "2026-09-01T00:00:00Z"
            ]
        ])
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed[0].kind, .weekly)
        XCTAssertEqual(mixed[0].usedPercent, 45, accuracy: 0.01)
        XCTAssertNotNil(mixed[0].resetsAt)
    }

    func testIgnoresDeviceCodeAndPlainXAIKey() {
        XCTAssertFalse(GrokQuotaService.looksLikeSessionToken("ABCD-EFGH"))
        XCTAssertFalse(GrokQuotaService.looksLikeSessionToken("xai-plain-key"))
        XCTAssertTrue(GrokQuotaService.looksLikeSessionToken("eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        XCTAssertNil(
            GrokQuotaService.sessionToken(from: [
                "api_key": "xai-plain-key",
                "key": "xai-plain-key"
            ])
        )
    }
}
