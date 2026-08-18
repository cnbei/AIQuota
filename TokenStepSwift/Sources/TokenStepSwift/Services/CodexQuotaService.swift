import Foundation

enum CodexQuotaService {
    private static let requestID = 2
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static var authURL: URL = {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }()

    static func read() throws -> CodexQuotaSnapshot {
        if let snapshot = try? readViaAppServer(), snapshot.isAvailable {
            return snapshot
        }
        return try readViaAuthJSON()
    }

    static func snapshot(fromUsageJSON json: [String: Any], fetchedAt: Date = Date()) -> CodexQuotaSnapshot {
        let rate = (json["rate_limit"] as? [String: Any]) ?? json
        var fiveHour: CodexQuotaWindow?
        var sevenDay: CodexQuotaWindow?
        for key in ["primary_window", "secondary_window", "primary", "secondary"] {
            guard let payload = rate[key] as? [String: Any] else { continue }
            guard let used = QuotaJSON.number(payload["used_percent"] ?? payload["usedPercent"]) else { continue }
            let seconds = QuotaJSON.number(payload["limit_window_seconds"] ?? payload["windowDurationMins"]) ?? 0
            let kind: CodexQuotaWindow.Kind?
            if seconds == 300 || seconds == 18_000 {
                kind = .fiveHour
            } else if seconds == 10_080 || seconds == 604_800 {
                kind = .sevenDay
            } else if fiveHour == nil {
                kind = .fiveHour
            } else if sevenDay == nil {
                kind = .sevenDay
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let resetsAt = QuotaAuth.date(from: payload["reset_at"] ?? payload["resetsAt"])
                ?? QuotaJSON.number(payload["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
            let window = CodexQuotaWindow(kind: kind, usedPercent: used, resetsAt: resetsAt)
            if kind == .fiveHour, fiveHour == nil {
                fiveHour = window
            } else if kind == .sevenDay, sevenDay == nil {
                sevenDay = window
            }
        }
        return CodexQuotaSnapshot(
            fetchedAt: fetchedAt,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            planName: json["plan_type"] as? String ?? json["planType"] as? String
        )
    }

    private static func readViaAppServer() throws -> CodexQuotaSnapshot {
        let output = try runAppServerRequest()
        let response = try parseRateLimitResponse(output)
        let snapshot = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        let windows = classifiedWindows(snapshot)
        return CodexQuotaSnapshot(
            fetchedAt: Date(),
            fiveHour: window(windows.fiveHour, kind: .fiveHour),
            sevenDay: window(windows.sevenDay, kind: .sevenDay)
        )
    }

    private static func readViaAuthJSON() throws -> CodexQuotaSnapshot {
        guard var auth = loadAuth() else {
            throw TokenStepError.message(L("暂未读取到 Codex 额度"))
        }
        if QuotaAuth.needsRefresh(auth.accessToken), !auth.refreshToken.isEmpty {
            if let refreshed = try? refreshTokens(auth.refreshToken) {
                applyRefresh(&auth, refreshed)
                saveAuth(auth)
            }
        }
        guard !auth.accessToken.isEmpty else {
            throw TokenStepError.message(L("暂未读取到 Codex 额度"))
        }
        var (data, http) = try fetchUsage(accessToken: auth.accessToken, accountID: auth.accountID)
        if (http.statusCode == 401 || http.statusCode == 403), !auth.refreshToken.isEmpty {
            let refreshed = try refreshTokens(auth.refreshToken)
            applyRefresh(&auth, refreshed)
            saveAuth(auth)
            (data, http) = try fetchUsage(accessToken: auth.accessToken, accountID: auth.accountID)
        }
        guard (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TokenStepError.message(L("暂未读取到 Codex 额度"))
        }
        let snapshot = snapshot(fromUsageJSON: json)
        guard snapshot.isAvailable else {
            throw TokenStepError.message(L("暂未读取到 Codex 额度"))
        }
        return snapshot
    }

    private struct CodexAuth {
        var root: [String: Any]
        var tokens: [String: Any]
        var accessToken: String
        var refreshToken: String
        var accountID: String?
    }

    private static func loadAuth() -> CodexAuth? {
        guard FileManager.default.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let tokens = (root["tokens"] as? [String: Any]) ?? [:]
        let access = (tokens["access_token"] as? String) ?? ""
        let refresh = (tokens["refresh_token"] as? String) ?? ""
        let account = tokens["account_id"] as? String
        guard !access.isEmpty || !refresh.isEmpty else { return nil }
        return CodexAuth(
            root: root,
            tokens: tokens,
            accessToken: access,
            refreshToken: refresh,
            accountID: account
        )
    }

    private static func applyRefresh(_ auth: inout CodexAuth, _ refreshed: (access: String, refresh: String?, idToken: String?)) {
        auth.accessToken = refreshed.access
        auth.tokens["access_token"] = refreshed.access
        if let refresh = refreshed.refresh, !refresh.isEmpty {
            auth.refreshToken = refresh
            auth.tokens["refresh_token"] = refresh
        }
        if let idToken = refreshed.idToken, !idToken.isEmpty {
            auth.tokens["id_token"] = idToken
        }
        auth.root["tokens"] = auth.tokens
        auth.root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    }

    private static func saveAuth(_ auth: CodexAuth) {
        guard JSONSerialization.isValidJSONObject(auth.root),
              let data = try? JSONSerialization.data(withJSONObject: auth.root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: authURL, options: .atomic)
    }

    private static func refreshTokens(_ refreshToken: String) throws -> (access: String, refresh: String?, idToken: String?) {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = QuotaAuth.formEncoded([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ])
        let (data, http) = try HTTPJSONClient.exchange(request)
        guard (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty
        else {
            throw TokenStepError.message(L("暂未读取到 Codex 额度"))
        }
        return (access, json["refresh_token"] as? String, json["id_token"] as? String)
    }

    private static func fetchUsage(accessToken: String, accountID: String?) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIQuota", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return try HTTPJSONClient.exchange(request)
    }

    private static func window(_ payload: RateLimitWindowPayload?, kind: CodexQuotaWindow.Kind) -> CodexQuotaWindow? {
        guard let payload else { return nil }
        return CodexQuotaWindow(
            kind: kind,
            usedPercent: payload.usedPercent,
            resetsAt: payload.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private static func classifiedWindows(_ snapshot: RateLimitSnapshotPayload) -> (fiveHour: RateLimitWindowPayload?, sevenDay: RateLimitWindowPayload?) {
        var fiveHour: RateLimitWindowPayload?
        var sevenDay: RateLimitWindowPayload?

        for payload in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
            switch payload.windowDurationMins {
            case 300:
                if fiveHour == nil { fiveHour = payload }
            case 10_080:
                if sevenDay == nil { sevenDay = payload }
            default:
                continue
            }
        }

        if fiveHour == nil, sevenDay == nil {
            return (fiveHour: snapshot.primary, sevenDay: snapshot.secondary)
        }

        return (fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func runAppServerRequest() throws -> String {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputLock = NSLock()
        let errorLock = NSLock()
        let responseSemaphore = DispatchSemaphore(value: 0)
        var output = Data()
        var errorOutput = Data()
        var didReceiveQuotaResponse = false

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server", "--listen", "stdio://"]
        process.environment = appServerEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            output.append(data)
            if !didReceiveQuotaResponse,
               let text = String(data: output, encoding: .utf8),
               text.contains("\"id\":\(requestID)") {
                didReceiveQuotaResponse = true
                responseSemaphore.signal()
            }
            outputLock.unlock()
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errorLock.lock()
            errorOutput.append(data)
            errorLock.unlock()
        }
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        try process.run()
        do {
            try writeRequests(to: inputPipe.fileHandleForWriting)
        } catch {
            process.terminate()
            throw error
        }

        let _ = responseSemaphore.wait(timeout: .now() + 4)
        process.terminate()

        let exitSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exitSemaphore.signal()
        }

        _ = exitSemaphore.wait(timeout: .now() + 1)

        outputLock.lock()
        let outputData = output
        outputLock.unlock()
        errorLock.lock()
        let stderrData = errorOutput
        errorLock.unlock()

        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        if outputText.contains("\"id\":\(requestID)") {
            return outputText
        }

        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TokenStepError.message(stderrText)
        }
        throw TokenStepError.message(L("暂未读取到 Codex 额度"))
    }

    private static func writeRequests(to handle: FileHandle) throws {
        let initialize: [String: Any] = [
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "tokenstep",
                    "title": "TokenStep",
                    "version": UpdateService.currentVersion
                ],
                "capabilities": NSNull()
            ]
        ]
        let quota: [String: Any] = [
            "method": "account/rateLimits/read",
            "id": requestID
        ]

        for request in [initialize, quota] {
            let data = try JSONSerialization.data(withJSONObject: request)
            try write(data, to: handle)
            try write(Data("\n".utf8), to: handle)
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw TokenStepError.message(L("暂未读取到 Codex 额度"))
        }
    }

    private static func parseRateLimitResponse(_ text: String) throws -> GetAccountRateLimitsPayload {
        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let data = String(line).data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["id"] as? Int == requestID
            else { continue }

            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw TokenStepError.message(message)
            }

            guard let result = object["result"] else {
                throw TokenStepError.message(L("暂未读取到 Codex 额度"))
            }
            let resultData = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(GetAccountRateLimitsPayload.self, from: resultData)
        }

        throw TokenStepError.message(L("暂未读取到 Codex 额度"))
    }

    private static func appServerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = "\(defaultPath):\(existing)"
        } else {
            environment["PATH"] = defaultPath
        }
        return environment
    }
}

private struct GetAccountRateLimitsPayload: Decodable {
    var rateLimits: RateLimitSnapshotPayload
    var rateLimitsByLimitId: [String: RateLimitSnapshotPayload]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
    }
}

private struct RateLimitSnapshotPayload: Decodable {
    var primary: RateLimitWindowPayload?
    var secondary: RateLimitWindowPayload?
}

private struct RateLimitWindowPayload: Decodable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Int?
}
