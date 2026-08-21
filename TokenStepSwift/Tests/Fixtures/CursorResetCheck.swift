#if TOKENSTEP_TESTING
import Foundation

@main
enum CursorResetCheck {
    static func main() throws {
        let unix = CursorQuotaService.windows(from: [
            "billingCycleEnd": "1789516800000",
            "planUsage": ["autoPercentUsed": 12, "apiPercentUsed": 3]
        ])
        try expect(unix.first?.resetsAt == Date(timeIntervalSince1970: 1_789_516_800), "unix ms reset")

        let proto = CursorQuotaService.windows(from: [
            "planInfo": ["billingCycleEnd": ["seconds": 1_789_516_800, "nanos": 0]],
            "planUsage": ["autoPercentUsed": 4, "apiPercentUsed": 1]
        ])
        try expect(proto.first?.resetsAt == Date(timeIntervalSince1970: 1_789_516_800), "protobuf reset")

        let dashboard: [String: Any] = [
            "planUsage": ["autoPercentUsed": 11.9, "apiPercentUsed": 32.8]
        ]
        try expect(CursorQuotaService.resetDate(from: dashboard) == nil, "dashboard missing reset")
        let merged = CursorQuotaService.applyingBillingCycleFallback(
            dashboard,
            fallback: ["billingCycleEnd": "2026-09-16T00:00:00.000Z"]
        )
        let windows = CursorQuotaService.windows(from: merged)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try expect(
            windows.first?.resetsAt == fractional.date(from: "2026-09-16T00:00:00.000Z"),
            "summary fallback"
        )
        print("cursor-reset-check: ok")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "CursorResetCheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
#endif
