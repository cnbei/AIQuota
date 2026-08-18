import Foundation

enum UsageSyncService {
    private static let gitTimeoutSeconds: TimeInterval = 25
    private static let maxPushRetries = 2

    struct MachineIdentity: Codable {
        var id: String
        var name: String
        var fileSlug: String

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case fileSlug = "file_slug"
        }
    }

    struct MachineUsageFile: Codable {
        var machineId: String
        var machineName: String
        var updatedAt: String
        var daily: [DailyUsage]

        enum CodingKeys: String, CodingKey {
            case machineId = "machine_id"
            case machineName = "machine_name"
            case updatedAt = "updated_at"
            case daily
        }
    }

    private struct OthersDailyCache: Codable {
        var fetchedAt: Date
        var daily: [DailyUsage]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case daily
        }
    }

    /// Syncs this machine's daily usage to the shared git repo and returns the
    /// merged daily usage contributed by every *other* machine (never includes
    /// this machine's own data, so callers can add it on top of their local ledger
    /// without double counting).
    @discardableResult
    static func sync(
        remoteURLString: String,
        localSnapshot: UsageSnapshot,
        historyDays: Int
    ) throws -> [DailyUsage] {
        let remote = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { throw UsageSyncError.emptyRemoteURL }

        let identity = loadOrCreateMachineIdentity()
        let repoRoot = AppPaths.syncRepoRoot
        let branch = try prepareLocalRepo(remote: remote, repoRoot: repoRoot)

        try writeLocalMachineFile(
            identity: identity,
            snapshot: localSnapshot,
            historyDays: historyDays,
            repoRoot: repoRoot
        )
        try commitAndPushIfNeeded(repoRoot: repoRoot, branch: branch, machineName: identity.name)

        let others = readOthersDaily(repoRoot: repoRoot, excludingFileSlug: identity.fileSlug)
        writeCache(others)
        return others
    }

    static func loadCachedOthersDaily() -> [DailyUsage] {
        guard let data = try? Data(contentsOf: AppPaths.syncOthersDailyCacheJSON),
              let cache = try? JSONDecoder().decode(OthersDailyCache.self, from: data)
        else {
            return []
        }
        return cache.daily
    }

    // MARK: - Machine identity

    static func loadOrCreateMachineIdentity() -> MachineIdentity {
        if let data = try? Data(contentsOf: AppPaths.syncMachineIdentityJSON),
           let identity = try? JSONDecoder().decode(MachineIdentity.self, from: data) {
            return identity
        }
        let identity = makeMachineIdentity()
        persistMachineIdentity(identity)
        return identity
    }

    private static func makeMachineIdentity() -> MachineIdentity {
        let id = UUID().uuidString
        let rawName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostName = ProcessInfo.processInfo.hostName
        let name = sanitizedMachineName((rawName?.isEmpty == false ? rawName : nil) ?? hostName)
        let suffix = id.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        let base = slug(from: name)
        let fileSlug = base.isEmpty ? "machine-\(suffix)" : "\(base)-\(suffix)"
        return MachineIdentity(id: id, name: name, fileSlug: fileSlug)
    }

    private static func sanitizedMachineName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".local") {
            name = String(name.dropLast(".local".count))
        }
        return name.isEmpty ? "Mac" : name
    }

    private static func slug(from name: String) -> String {
        let chars = name.lowercased().unicodeScalars.map { scalar -> Character in
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        var result = String(chars)
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func persistMachineIdentity(_ identity: MachineIdentity) {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.syncMachineIdentityJSON.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(identity)
            try data.write(to: AppPaths.syncMachineIdentityJSON, options: .atomic)
        } catch {
            // Best effort: if this fails we simply regenerate a (new) identity on next launch.
        }
    }

    // MARK: - Repo preparation

    private static func prepareLocalRepo(remote: String, repoRoot: URL) throws -> String {
        let gitDir = repoRoot.appendingPathComponent(".git")
        if !FileManager.default.fileExists(atPath: gitDir.path) {
            try FileManager.default.createDirectory(
                at: repoRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: repoRoot)
            _ = try runGit(["clone", "--quiet", remote, repoRoot.path])
        } else {
            _ = try runGit(["remote", "set-url", "origin", remote], cwd: repoRoot)
            _ = try runGit(["fetch", "--quiet", "origin"], cwd: repoRoot)
        }

        if let branch = remoteBranchName(repoRoot: repoRoot, candidates: ["main", "master"]) {
            _ = try runGit(["checkout", "-B", branch, "origin/\(branch)"], cwd: repoRoot)
            return branch
        }
        _ = try runGit(["checkout", "-B", "main"], cwd: repoRoot)
        return "main"
    }

    private static func remoteBranchName(repoRoot: URL, candidates: [String]) -> String? {
        for name in candidates {
            if (try? runGit(["rev-parse", "--verify", "--quiet", "origin/\(name)"], cwd: repoRoot)) != nil {
                return name
            }
        }
        return nil
    }

    // MARK: - Writing this machine's file

    private static func writeLocalMachineFile(
        identity: MachineIdentity,
        snapshot: UsageSnapshot,
        historyDays: Int,
        repoRoot: URL,
        now: Date = Date()
    ) throws {
        let cutoff = cutoffDateKey(historyDays: historyDays, now: now)
        let daily = snapshot.daily
            .filter { $0.totalTokens > 0 && $0.date >= cutoff }
            .sorted { $0.date < $1.date }
        let file = MachineUsageFile(
            machineId: identity.id,
            machineName: identity.name,
            updatedAt: isoFormatter.string(from: now),
            daily: daily
        )

        let machinesDir = repoRoot.appendingPathComponent("machines", isDirectory: true)
        try FileManager.default.createDirectory(at: machinesDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw UsageSyncError.encodingFailed
        }
        let fileURL = machinesDir.appendingPathComponent("\(identity.fileSlug).json")
        try data.write(to: fileURL, options: .atomic)
    }

    private static func cutoffDateKey(historyDays: Int, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let days = max(1, historyDays)
        let cutoffDate = calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: calendar.startOfDay(for: now)
        ) ?? now
        return DateFormatter.tokenStepDay.string(from: cutoffDate)
    }

    // MARK: - Commit & push

    private static func commitAndPushIfNeeded(
        repoRoot: URL,
        branch: String,
        machineName: String,
        now: Date = Date()
    ) throws {
        _ = try runGit(["add", "-A", "--", "machines"], cwd: repoRoot)
        let status = try runGit(["status", "--porcelain", "--", "machines"], cwd: repoRoot)
        guard !status.isEmpty else { return }

        let timestamp = DateFormatter.tokenStepDay.string(from: now)
        _ = try runGit(
            [
                "-c", "user.email=sync@aiquota.app",
                "-c", "user.name=AIQuota Sync",
                "commit", "-m", "sync: \(machineName) \(timestamp)"
            ],
            cwd: repoRoot
        )
        try pushWithRetry(repoRoot: repoRoot, branch: branch)
    }

    private static func pushWithRetry(repoRoot: URL, branch: String) throws {
        var attempt = 0
        while true {
            do {
                _ = try runGit(["push", "origin", "HEAD:\(branch)"], cwd: repoRoot)
                return
            } catch {
                attempt += 1
                guard attempt <= maxPushRetries else { throw error }
                _ = try runGit(["fetch", "--quiet", "origin"], cwd: repoRoot)
                do {
                    _ = try runGit(["rebase", "origin/\(branch)"], cwd: repoRoot)
                } catch {
                    _ = try? runGit(["rebase", "--abort"], cwd: repoRoot)
                    throw UsageSyncError.rebaseConflict
                }
            }
        }
    }

    // MARK: - Reading other machines

    private static func readOthersDaily(repoRoot: URL, excludingFileSlug fileSlug: String) -> [DailyUsage] {
        let machinesDir = repoRoot.appendingPathComponent("machines", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: machinesDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let excludedName = "\(fileSlug).json"
        let decoder = JSONDecoder()
        var merged: [String: DailyUsage] = [:]
        for fileURL in files {
            guard fileURL.pathExtension == "json", fileURL.lastPathComponent != excludedName else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let machineFile = try? decoder.decode(MachineUsageFile.self, from: data)
            else { continue }
            for day in machineFile.daily {
                merged[day.date] = mergedDay(merged[day.date], day)
            }
        }
        return merged.values.sorted { $0.date < $1.date }
    }

    private static func mergedDay(_ existing: DailyUsage?, _ incoming: DailyUsage) -> DailyUsage {
        guard var result = existing else { return incoming }
        result.totalTokens += incoming.totalTokens
        result.cost += incoming.cost
        for (tool, tokens) in incoming.tools {
            result.tools[tool, default: 0] += tokens
        }
        for (model, tokens) in incoming.models {
            result.models[model, default: 0] += tokens
        }
        return result
    }

    private static func writeCache(_ daily: [DailyUsage], now: Date = Date()) {
        let cache = OthersDailyCache(fetchedAt: now, daily: daily)
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.syncOthersDailyCacheJSON.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: AppPaths.syncOthersDailyCacheJSON, options: .atomic)
        } catch {
            // Cache is best-effort; a stale/missing cache just delays "others" data showing up.
        }
    }

    // MARK: - Git process helper

    @discardableResult
    private static func runGit(_ arguments: [String], cwd: URL? = nil, timeout: TimeInterval = gitTimeoutSeconds) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw UsageSyncError.gitNotFound
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw UsageSyncError.gitTimedOut
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 127 {
                throw UsageSyncError.gitNotFound
            }
            throw UsageSyncError.gitFailed(output)
        }
        return output
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum UsageSyncError: LocalizedError {
    case emptyRemoteURL
    case gitNotFound
    case gitTimedOut
    case gitFailed(String)
    case encodingFailed
    case rebaseConflict

    var errorDescription: String? {
        switch self {
        case .emptyRemoteURL:
            return L("同步仓库地址为空，请先填写有效的 git 仓库地址")
        case .gitNotFound:
            return L("未找到 git 命令，请确认已安装 Xcode 命令行工具")
        case .gitTimedOut:
            return L("git 操作超时，请检查网络后重试")
        case let .gitFailed(output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return L("git 操作失败") }
            return LFormat("git 操作失败：%@", String(trimmed.suffix(200)))
        case .encodingFailed:
            return L("同步数据序列化失败")
        case .rebaseConflict:
            return L("检测到冲突，已放弃这次推送，下次会重试")
        }
    }
}
