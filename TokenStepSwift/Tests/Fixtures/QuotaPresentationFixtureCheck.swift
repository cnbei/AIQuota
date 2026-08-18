import Foundation

@main
struct QuotaPresentationFixtureCheck {
    static func main() throws {
        let quota = ProviderQuota(
            provider: .cursor,
            windows: [
                QuotaWindow(kind: .monthlyCredits, usedPercent: 10, remaining: 90, total: 100, title: "总体"),
                QuotaWindow(kind: .cursorModels, usedPercent: 40, remaining: 60, total: 100),
                QuotaWindow(kind: .otherModels, usedPercent: 80, remaining: 20, total: 100)
            ],
            status: .available,
            metrics: QuotaMetrics(
                cursorIncludedUsed: 10,
                cursorModelsUsed: 40,
                otherModelsUsed: 80,
                cursorSpendDollars: 2.4,
                cursorLimitDollars: 20
            )
        )
        try assertNear(QuotaPresentation.remainingPercent(quota, cursorMode: .included, kimiMode: .membership), 60)
        try assertNear(QuotaPresentation.remainingPercent(quota, cursorMode: .cursorModels, kimiMode: .membership), 60)
        try assertNear(QuotaPresentation.remainingPercent(quota, cursorMode: .otherModels, kimiMode: .membership), 20)
        let cursorDetail = QuotaPresentation.detail(quota, cursorMode: .included, kimiMode: .membership)
        try assertTrue(cursorDetail.contains("$2.40"))
        try assertTrue(cursorDetail.contains("Other Models"))

        let spendVsPools = ProviderQuota(
            provider: .cursor,
            windows: [
                QuotaWindow(kind: .monthlyCredits, usedPercent: 10.335, remaining: 89.665, total: 100, title: "套餐花费"),
                QuotaWindow(kind: .cursorModels, usedPercent: 2, remaining: 98, total: 100),
                QuotaWindow(kind: .otherModels, usedPercent: 0, remaining: 100, total: 100)
            ],
            status: .available,
            metrics: QuotaMetrics(
                cursorIncludedUsed: 10.335,
                cursorModelsUsed: 2,
                otherModelsUsed: 0,
                cursorSpendDollars: 41.34,
                cursorLimitDollars: 400
            )
        )
        try assertNear(
            QuotaPresentation.remainingPercent(spendVsPools, cursorMode: .included, kimiMode: .membership),
            98
        )
        try assertNear(
            QuotaPresentation.remainingPercent(spendVsPools, cursorMode: .cursorModels, kimiMode: .membership),
            98
        )
        try assertNear(
            QuotaPresentation.remainingPercent(spendVsPools, cursorMode: .otherModels, kimiMode: .membership),
            100
        )

        let kimi = ProviderQuota(
            provider: .kimi,
            windows: [
                QuotaWindow(kind: .monthlyCredits, usedPercent: 86.4, remaining: 13.6, total: 100, title: "总使用量"),
                QuotaWindow(kind: .fiveHour, usedPercent: 0, remaining: 100, total: 100, title: "Code"),
                QuotaWindow(kind: .sevenDay, usedPercent: 2.6, remaining: 97.4, total: 100, title: "Code")
            ],
            status: .available,
            metrics: QuotaMetrics(kimiMembershipUsed: 86.4, kimiCodeUsed: 2.6)
        )
        try assertNear(QuotaPresentation.remainingPercent(kimi, cursorMode: .included, kimiMode: .membership), 13.6)
        try assertNear(QuotaPresentation.remainingPercent(kimi, cursorMode: .included, kimiMode: .code), 97.4)

        let now = Date()
        try assertEqual(QuotaResetFormat.relative(now.addingTimeInterval(-10), now: now), "已重置")
        try assertEqual(QuotaResetFormat.relative(now.addingTimeInterval(90 * 60), now: now), "1h 30m")

        let windows = [
            QuotaWindow(kind: .weekly, usedPercent: 2, title: "本周共用"),
            QuotaWindow(kind: .weekly, usedPercent: 1, title: "Grok Build")
        ]
        try assertEqual(Set(windows.map(\.id)).count, 2)

        let paceNow = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHours: TimeInterval = 5 * 3600
        try assertTrue(
            QuotaPaceCalculator.pace(
                usedPercent: 40,
                resetsAt: paceNow.addingTimeInterval(fiveHours * 0.98),
                kind: .fiveHour,
                now: paceNow
            ) == nil
        )

        let midWindow = paceNow.addingTimeInterval(fiveHours * 0.5)
        guard let onPace = QuotaPaceCalculator.pace(
            usedPercent: 50,
            resetsAt: midWindow,
            kind: .fiveHour,
            now: paceNow
        ) else {
            throw NSError(domain: "QuotaPresentationFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected on-pace result"
            ])
        }
        try assertEqual(onPace.kind, .onPace)
        try assertNear(onPace.expectedUsedPercent, 50)

        guard let deficit = QuotaPaceCalculator.pace(
            usedPercent: 70,
            resetsAt: midWindow,
            kind: .fiveHour,
            now: paceNow
        ) else {
            throw NSError(domain: "QuotaPresentationFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected deficit result"
            ])
        }
        try assertEqual(deficit.kind, .deficit)
        try assertNear(deficit.deltaPercent, 20)
        try assertTrue(deficit.eta != nil)
        try assertEqual(deficit.lastsUntilReset, false)

        guard let reserve = QuotaPaceCalculator.pace(
            usedPercent: 20,
            resetsAt: midWindow,
            kind: .fiveHour,
            now: paceNow
        ) else {
            throw NSError(domain: "QuotaPresentationFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected reserve result"
            ])
        }
        try assertEqual(reserve.kind, .reserve)
        try assertNear(reserve.deltaPercent, -30)
        try assertEqual(reserve.lastsUntilReset, true)

        try assertTrue(
            QuotaPaceCalculator.pace(
                usedPercent: 40,
                resetsAt: midWindow,
                kind: .cursorModels,
                now: paceNow
            ) == nil
        )

        guard let weekly = QuotaPaceCalculator.pace(
            usedPercent: 80,
            resetsAt: paceNow.addingTimeInterval(7 * 24 * 3600 * 0.5),
            kind: .weekly,
            now: paceNow
        ) else {
            throw NSError(domain: "QuotaPresentationFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected weekly deficit result"
            ])
        }
        try assertEqual(weekly.kind, .deficit)

        let freshJWT = jwt(exp: Date().timeIntervalSince1970 + 3600)
        let staleJWT = jwt(exp: Date().timeIntervalSince1970 - 60)
        try assertTrue(!QuotaAuth.needsRefresh(freshJWT))
        try assertTrue(QuotaAuth.needsRefresh(staleJWT))

        print("quota presentation fixture ok")
    }

    private static func jwt(exp: TimeInterval) -> String {
        let payload = ["exp": exp]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        var encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while encoded.last == "=" {
            encoded.removeLast()
        }
        return "aaa.\(encoded).bbb"
    }

    private static func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T) throws {
        guard lhs == rhs else {
            throw NSError(domain: "QuotaPresentationFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected \(rhs), got \(lhs)"
            ])
        }
    }

    private static func assertTrue(_ value: Bool) throws {
        try assertEqual(value, true)
    }

    private static func assertNear(_ lhs: Double, _ rhs: Double, accuracy: Double = 0.01) throws {
        guard abs(lhs - rhs) <= accuracy else {
            throw NSError(domain: "QuotaPresentationFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected \(rhs), got \(lhs)"
            ])
        }
    }
}
