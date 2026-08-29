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

    struct MachineUsageFile: Codable, Equatable {
        var machineId: String
        var machineName: String
        var fileSlug: String?
        var updatedAt: String
        var daily: [DailyUsage]

        enum CodingKeys: String, CodingKey {
            case machineId = "machine_id"
            case machineName = "machine_name"
            case fileSlug = "file_slug"
            case updatedAt = "updated_at"
            case daily
        }
    }

    private struct OthersMachinesCache: Codable {
        var fetchedAt: Date
        var machines: [MachineUsageFile]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case machines
        }
    }

    struct UsageSyncResult: Equatable {
        var others: [MachineUsageFile]
        var mergedLocalDaily: [DailyUsage]
    }

    /// Syncs this machine's lifetime daily usage to the shared git repo and
    /// returns every *other* machine plus the high-water local ledger. This
    /// machine's own file is never included in `others`.
    @discardableResult
    static func sync(
        remoteURLString: String,
        localSnapshot: UsageSnapshot,
        historyDays _: Int
    ) throws -> UsageSyncResult {
        let remote = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else { throw UsageSyncError.emptyRemoteURL }

        let identity = loadOrCreateMachineIdentity()
        let repoRoot = AppPaths.syncRepoRoot
        let branch = try prepareLocalRepo(remote: remote, repoRoot: repoRoot)

        let mergedLocalDaily = try writeLocalMachineFile(
            identity: identity,
            snapshot: localSnapshot,
            repoRoot: repoRoot
        )
        try persistCursorAccountFile(repoRoot: repoRoot)
        try restoreRicherRemoteFiles(repoRoot: repoRoot, excludingFileSlug: identity.fileSlug)
        try commitAndPushIfNeeded(repoRoot: repoRoot, branch: branch, machineName: identity.name)

        let others = highWaterOthers(
            readOthersMachines(repoRoot: repoRoot, excludingFileSlug: identity.fileSlug)
        )
        writeCache(others)
        return UsageSyncResult(others: others, mergedLocalDaily: mergedLocalDaily)
    }

    static func loadCachedOthersMachines() -> [MachineUsageFile] {
        guard let data = try? Data(contentsOf: AppPaths.syncOthersMachinesCacheJSON) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cache = try? decoder.decode(OthersMachinesCache.self, from: data) {
            return cache.machines
        }
        return []
    }

    static func loadCachedOthersDaily() -> [DailyUsage] {
        HistoryDevicePresentation.mergedDaily(
            from: loadCachedOthersMachines().map { SyncedMachineLedger(remote: $0) }
        )
    }

    static func loadCachedCursorAccount() -> MachineUsageFile? {
        guard let data = try? Data(contentsOf: AppPaths.syncCursorAccountCacheJSON) else {
            return nil
        }
        return try? JSONDecoder().decode(MachineUsageFile.self, from: data)
    }

    static func loadPersistedCursorAccountDaily() -> [DailyUsage] {
        if let cached = loadCachedCursorAccount()?.daily, cached.contains(where: { $0.totalTokens > 0 }) {
            return cached.filter { $0.totalTokens > 0 }
        }
        return readMachineFile(at: cursorAccountFileURL(repoRoot: AppPaths.syncRepoRoot))?.daily
            .filter { $0.totalTokens > 0 } ?? []
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

    @discardableResult
    private static func writeLocalMachineFile(
        identity: MachineIdentity,
        snapshot: UsageSnapshot,
        repoRoot: URL,
        now: Date = Date()
    ) throws -> [DailyUsage] {
        let fileURL = machineFileURL(repoRoot: repoRoot, fileSlug: identity.fileSlug)
        let existing = readMachineFile(at: fileURL)
        let incoming = CursorUsageService.localDeviceDaily(from: snapshot, shouldStripCursor: true)
        let daily = UsageHighWaterMerge.days(existing?.daily ?? [], incoming)
        let file = MachineUsageFile(
            machineId: identity.id,
            machineName: identity.name,
            fileSlug: identity.fileSlug,
            updatedAt: isoFormatter.string(from: now),
            daily: daily
        )
        try writeMachineFile(file, to: fileURL)
        return daily
    }

    private static func persistCursorAccountFile(repoRoot: URL, now: Date = Date()) throws {
        let fileURL = cursorAccountFileURL(repoRoot: repoRoot)
        let existing = readMachineFile(at: fileURL)
        let cacheDaily = CursorUsageService.accountDeviceDaily(from: CursorUsageService.readCache()?.days ?? [])
        let daily = UsageHighWaterMerge.days(
            UsageHighWaterMerge.days(existing?.daily ?? [], loadCachedCursorAccount()?.daily ?? []),
            cacheDaily
        )
        guard !daily.isEmpty else { return }

        let file = MachineUsageFile(
            machineId: CursorUsageService.accountDeviceID,
            machineName: "Cursor 账号",
            fileSlug: CursorUsageService.accountDeviceID,
            updatedAt: isoFormatter.string(from: now),
            daily: daily
        )
        try writeMachineFile(file, to: fileURL)
        writeCursorAccountCache(file)
        absorbCursorDaysIntoLocalCache(daily)
    }

    private static func restoreRicherRemoteFiles(repoRoot: URL, excludingFileSlug fileSlug: String) throws {
        let cachedBySlug = Dictionary(
            uniqueKeysWithValues: loadCachedOthersMachines().compactMap { file -> (String, MachineUsageFile)? in
                let slug = resolvedSlug(file)
                guard slug != fileSlug, slug != CursorUsageService.accountDeviceID else { return nil }
                return (slug, file)
            }
        )
        for remote in readOthersMachines(repoRoot: repoRoot, excludingFileSlug: fileSlug) {
            let slug = resolvedSlug(remote)
            let mergedDaily = UsageHighWaterMerge.days(cachedBySlug[slug]?.daily ?? [], remote.daily)
            guard UsageHighWaterMerge.isRicher(mergedDaily, than: remote.daily) else { continue }
            var restored = remote
            restored.daily = mergedDaily
            restored.fileSlug = slug
            try writeMachineFile(restored, to: machineFileURL(repoRoot: repoRoot, fileSlug: slug))
        }
    }

    private static func highWaterOthers(_ incoming: [MachineUsageFile]) -> [MachineUsageFile] {
        let cachedBySlug = Dictionary(
            uniqueKeysWithValues: loadCachedOthersMachines().map { (resolvedSlug($0), $0) }
        )
        var mergedBySlug: [String: MachineUsageFile] = [:]
        for file in incoming {
            let slug = resolvedSlug(file)
            guard slug != CursorUsageService.accountDeviceID else { continue }
            var merged = file
            merged.fileSlug = slug
            merged.daily = UsageHighWaterMerge.days(cachedBySlug[slug]?.daily ?? [], file.daily)
            mergedBySlug[slug] = merged
        }
        for (slug, cached) in cachedBySlug where mergedBySlug[slug] == nil && slug != CursorUsageService.accountDeviceID {
            mergedBySlug[slug] = cached
        }
        return mergedBySlug.values.sorted {
            $0.machineName.localizedCaseInsensitiveCompare($1.machineName) == .orderedAscending
        }
    }

    private static func absorbCursorDaysIntoLocalCache(_ daily: [DailyUsage]) {
        let originDays = daily.map(CursorUsageService.day(from:))
        let existing = CursorUsageService.readCache()
        let merged = CursorUsageService.mergeCursorDays(existing?.days ?? [], originDays)
        guard !merged.isEmpty else { return }
        CursorUsageService.writeCache(
            CursorUsageCache(fetchedAt: existing?.fetchedAt ?? Date(), days: merged)
        )
    }

    private static func writeCursorAccountCache(_ file: MachineUsageFile) {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.syncCursorAccountCacheJSON.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: AppPaths.syncCursorAccountCacheJSON, options: .atomic)
        } catch {
            // Cache is best-effort; Origin remains the durable copy.
        }
    }

    private static func writeMachineFile(_ file: MachineUsageFile, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            throw UsageSyncError.encodingFailed
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static func readMachineFile(at fileURL: URL) -> MachineUsageFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        var file = try? JSONDecoder().decode(MachineUsageFile.self, from: data)
        if file?.fileSlug == nil || file?.fileSlug?.isEmpty == true {
            file?.fileSlug = fileURL.deletingPathExtension().lastPathComponent
        }
        return file
    }

    private static func machineFileURL(repoRoot: URL, fileSlug: String) -> URL {
        repoRoot
            .appendingPathComponent("machines", isDirectory: true)
            .appendingPathComponent("\(fileSlug).json")
    }

    private static func cursorAccountFileURL(repoRoot: URL) -> URL {
        machineFileURL(repoRoot: repoRoot, fileSlug: CursorUsageService.accountDeviceID)
    }

    private static func resolvedSlug(_ file: MachineUsageFile) -> String {
        if let slug = file.fileSlug, !slug.isEmpty { return slug }
        return HistoryDevicePresentation.slug(from: file.machineId)
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

    private static func readOthersMachines(repoRoot: URL, excludingFileSlug fileSlug: String) -> [MachineUsageFile] {
        let machinesDir = repoRoot.appendingPathComponent("machines", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: machinesDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let excludedNames: Set<String> = [
            "\(fileSlug).json",
            "\(CursorUsageService.accountDeviceID).json"
        ]
        let decoder = JSONDecoder()
        var result: [MachineUsageFile] = []
        for fileURL in files {
            guard fileURL.pathExtension == "json", !excludedNames.contains(fileURL.lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  var machineFile = try? decoder.decode(MachineUsageFile.self, from: data)
            else { continue }
            if machineFile.fileSlug == nil || machineFile.fileSlug?.isEmpty == true {
                machineFile.fileSlug = fileURL.deletingPathExtension().lastPathComponent
            }
            if machineFile.machineId == CursorUsageService.accountDeviceID
                || machineFile.fileSlug == CursorUsageService.accountDeviceID {
                continue
            }
            result.append(machineFile)
        }
        return result.sorted { $0.machineName.localizedCaseInsensitiveCompare($1.machineName) == .orderedAscending }
    }

    private static func writeCache(_ machines: [MachineUsageFile], now: Date = Date()) {
        let cache = OthersMachinesCache(fetchedAt: now, machines: machines)
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.syncOthersMachinesCacheJSON.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: AppPaths.syncOthersMachinesCacheJSON, options: .atomic)
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
