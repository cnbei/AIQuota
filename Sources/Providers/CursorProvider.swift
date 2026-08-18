import Foundation

enum CursorProvider {
    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let planInfoURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    private static let restUsageURL = URL(string: "https://cursor.com/api/usage")!

    static func fetch() async -> QuotaSnapshot {
        do {
            guard let accessToken = try readAccessToken() else {
                return .failed(.cursor, message: "未找到 Cursor 登录态，请先在 Cursor 登录")
            }

            async let planInfoTask = fetchPlanInfo(accessToken: accessToken)
            let (data, response) = try await dashboardPost(usageURL, accessToken: accessToken)
            let planInfo = await planInfoTask

            if (200..<300).contains(response.statusCode),
               let json = HTTP.jsonObject(data),
               let snap = mapDashboard(json, planInfo: planInfo) {
                return snap
            }

            // Fallback: legacy request-count usage.
            if let session = session(from: accessToken) {
                var components = URLComponents(url: restUsageURL, resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "user", value: session.userID)]
                if let url = components?.url {
                    let (legacyData, legacyResp) = try await HTTP.get(
                        url,
                        headers: ["Cookie": "WorkosCursorSessionToken=\(session.cookieValue)"]
                    )
                    if (200..<300).contains(legacyResp.statusCode),
                       let json = HTTP.jsonObject(legacyData),
                       let snap = mapLegacy(json) {
                        return snap
                    }
                }
            }

            return .failed(.cursor, message: "Cursor 用量接口失败 (\(response.statusCode))")
        } catch {
            return .failed(.cursor, message: error.localizedDescription)
        }
    }

    private static func dashboardHeaders(_ accessToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "Accept": "application/json",
        ]
    }

    private static func dashboardPost(_ url: URL, accessToken: String) async throws -> (Data, HTTPURLResponse) {
        try await HTTP.post(url, headers: dashboardHeaders(accessToken), body: Data("{}".utf8))
    }

    private static func fetchPlanInfo(accessToken: String) async -> [String: Any]? {
        guard let (data, response) = try? await dashboardPost(planInfoURL, accessToken: accessToken),
              (200..<300).contains(response.statusCode),
              let json = HTTP.jsonObject(data)
        else { return nil }
        return (json["planInfo"] as? [String: Any]) ?? json
    }

    // MARK: - Local auth

    private static func dbPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private static func readAccessToken() throws -> String? {
        let path = dbPath().path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return readTokenViaCLI(path: path)
    }

    private static func readTokenViaCLI(path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        } catch {
            return nil
        }
    }

    private struct Session {
        var userID: String
        var cookieValue: String
    }

    private static func session(from accessToken: String) -> Session? {
        guard let payload = jwtPayload(accessToken) else { return nil }
        let sub = (payload["sub"] as? String) ?? ""
        let parts = sub.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return Session(userID: userID, cookieValue: "\(userID)%3A%3A\(accessToken)")
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Mapping

    private static func mapDashboard(_ json: [String: Any], planInfo: [String: Any]?) -> QuotaSnapshot? {
        // Spending 主进度条 = includedSpend / limit（displayMessage）。
        // autoPercentUsed / apiPercentUsed 是另一套内部指标，不是 spend/limit。
        let planUsage = (json["planUsage"] as? [String: Any])
            ?? (json["plan_usage"] as? [String: Any])
            ?? json

        let autoPercent = JSONPath.double(planUsage["autoPercentUsed"])
            ?? JSONPath.double(json["autoPercentUsed"])
        let apiPercent = JSONPath.double(planUsage["apiPercentUsed"])
            ?? JSONPath.double(json["apiPercentUsed"])

        let limitCents = JSONPath.double(planUsage["limit"])
            ?? JSONPath.double(planUsage["includedLimit"])
            ?? JSONPath.double(planInfo?["includedAmountCents"])
        let includedCents = JSONPath.double(planUsage["includedSpend"])
            ?? JSONPath.double(planUsage["used"])
            ?? JSONPath.double(planUsage["totalSpend"])
        let remainingCents = JSONPath.double(planUsage["remaining"])

        var includedPercent: Double?
        if let includedCents, let limitCents, limitCents > 0 {
            includedPercent = min(100, max(0, includedCents / limitCents * 100))
        } else if let remainingCents, let limitCents, limitCents > 0 {
            includedPercent = min(100, max(0, (1 - remainingCents / limitCents) * 100))
        }

        let usedForRing = includedPercent ?? autoPercent ?? apiPercent
        guard let usedForRing else { return nil }
        let remaining = max(0, min(100, 100 - usedForRing))

        let spendDollars = includedCents.map { $0 / 100 }
        let limitDollars = limitCents.map { $0 / 100 }

        var parts: [String] = []
        if let spendDollars, let limitDollars, limitDollars > 0 {
            parts.append(String(format: "$%.2f / $%.0f", spendDollars, limitDollars))
        }
        if let includedPercent {
            parts.append(String(format: "总体 %.0f%% used", includedPercent))
        }
        if let autoPercent {
            parts.append(String(format: "Cursor Models %.0f%%", autoPercent))
        }
        if let apiPercent {
            parts.append(String(format: "Other %.0f%%", apiPercent))
        }
        let usedDisplay = parts.isEmpty
            ? String(format: "%.0f%% left", remaining)
            : parts.joined(separator: " · ")

        let plan = JSONPath.string(planInfo?["planName"])
            ?? JSONPath.string(json["planName"])
            ?? JSONPath.string(json["membershipType"])
            ?? JSONPath.string((json["plan"] as? [String: Any])?["name"])

        var resetsAt: Date?
        if let end = parseCycleDate(json["billingCycleEnd"])
            ?? parseCycleDate(planInfo?["billingCycleEnd"]) {
            resetsAt = end
        }

        var windows: [QuotaWindow] = []
        if let includedPercent {
            windows.append(QuotaWindow(
                kind: .thirtyDay,
                title: "总体",
                usedPercent: includedPercent,
                resetsAt: resetsAt
            ))
        }
        if let autoPercent {
            windows.append(QuotaWindow(
                kind: .thirtyDay,
                title: "Cursor Models",
                usedPercent: autoPercent,
                resetsAt: resetsAt
            ))
        }
        if let apiPercent {
            windows.append(QuotaWindow(
                kind: .thirtyDay,
                title: "Other Models",
                usedPercent: apiPercent,
                resetsAt: resetsAt
            ))
        }

        let metrics = QuotaMetrics(
            cursorIncludedUsed: includedPercent,
            cursorModelsUsed: autoPercent,
            otherModelsUsed: apiPercent,
            cursorSpendDollars: spendDollars,
            cursorLimitDollars: limitDollars
        )

        return QuotaSnapshot(
            provider: .cursor,
            remainingPercent: remaining,
            detail: usedDisplay,
            planName: plan,
            windows: windows,
            updatedAt: Date(),
            error: nil,
            metrics: metrics
        )
    }

    private static func parseCycleDate(_ any: Any?) -> Date? {
        if let ms = JSONPath.double(any), ms > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let sec = JSONPath.double(any), sec > 1_000_000_000 {
            return Date(timeIntervalSince1970: sec)
        }
        if let s = JSONPath.string(any) {
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFrac.date(from: s) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
        }
        return nil
    }

    private static func mapLegacy(_ json: [String: Any]) -> QuotaSnapshot? {
        // Shape: { "gpt-4": { numRequests, maxRequestUsage }, startOfMonth }
        var best: (used: Double, max: Double)?
        for (_, value) in json {
            guard let bucket = value as? [String: Any] else { continue }
            let used = JSONPath.double(bucket["numRequests"])
            let maxV = JSONPath.double(bucket["maxRequestUsage"])
            guard let used, let maxV, maxV > 0 else { continue }
            if best == nil || maxV > best!.max {
                best = (used, maxV)
            }
        }
        guard let best else { return nil }
        let remaining = max(0, min(100, (1 - best.used / best.max) * 100))

        var resetsAt: Date?
        if let start = JSONPath.string(json["startOfMonth"]),
           let startDate = ISO8601DateFormatter().date(from: start) {
            resetsAt = Calendar.current.date(byAdding: .month, value: 1, to: startDate)
        }

        return QuotaSnapshot(
            provider: .cursor,
            remainingPercent: remaining,
            detail: String(format: "%.0f / %.0f requests", best.used, best.max),
            planName: nil,
            windows: [
                QuotaWindow(kind: .thirtyDay, title: "Requests", usedPercent: best.used / best.max * 100, resetsAt: resetsAt)
            ],
            updatedAt: Date(),
            error: nil
        )
    }
}
