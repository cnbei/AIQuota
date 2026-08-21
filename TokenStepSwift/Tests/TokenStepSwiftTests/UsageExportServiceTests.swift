import XCTest
@testable import TokenStepSwift

final class UsageExportServiceTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiquota-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testExportWritesJsonAndCsvWithoutIdentityFields() throws {
        let snapshot = UsageSnapshot(
            generatedAt: "2026-08-21T12:00:00Z",
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 15, cost: 1.5, activeDays: 2),
            daily: [
                DailyUsage(date: "2026-08-20", tools: ["Codex": 5], models: ["gpt-5": 5], totalTokens: 5, cost: 0.5),
                DailyUsage(date: "2026-08-21", tools: ["Claude Code": 10], models: ["opus": 10], totalTokens: 10, cost: 1)
            ],
            tools: [],
            models: [],
            sources: [:]
        )
        let now = DateFormatter.tokenStepDay.date(from: "2026-08-21")!

        let urls = try UsageExportService.export(snapshot: snapshot, to: folder, now: now)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), [
            UsageExportService.jsonFileName,
            UsageExportService.snapshotCSVFileName,
            UsageExportService.dailyCSVFileName
        ])

        let json = try String(contentsOf: folder.appendingPathComponent(UsageExportService.jsonFileName), encoding: .utf8)
        XCTAssertTrue(json.contains("\"name\" : \"AIQuota\""))
        XCTAssertTrue(json.contains("Claude Code"))
        XCTAssertFalse(json.contains("machine"))
        XCTAssertFalse(json.contains("email"))
        XCTAssertFalse(json.contains("quota"))

        let dailyData = try Data(contentsOf: folder.appendingPathComponent(UsageExportService.dailyCSVFileName))
        XCTAssertTrue(dailyData.starts(with: [0xEF, 0xBB, 0xBF]))
        let dailyCSV = String(decoding: dailyData, as: UTF8.self)
        XCTAssertTrue(dailyCSV.contains("2026-08-21,Claude Code,10,"))

        let document = UsageExportService.makeDocument(from: snapshot, now: now)
        XCTAssertEqual(document.snapshot.today.tokens, 10)
        XCTAssertEqual(document.snapshot.month.tokens, 15)
        XCTAssertEqual(document.snapshot.allTime.tokens, 15)
    }

    func testAutoExportSkipsUnchangedSnapshot() throws {
        var settings = TokenStepSettings.defaults
        settings.usageExportFolder = folder.path
        settings.usageExportAutoEnabled = true
        let snapshot = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 4, cost: 0, activeDays: 1),
            daily: [DailyUsage(date: "2026-08-21", tools: ["Codex": 4], totalTokens: 4, cost: 0)],
            tools: [],
            models: [],
            sources: [:]
        )
        let now = DateFormatter.tokenStepDay.date(from: "2026-08-21")!
        let first = try UsageExportService.autoExportIfEnabled(snapshot: snapshot, settings: settings, now: now)
        XCTAssertEqual(first?.count, 3)
        let second = try UsageExportService.autoExportIfEnabled(snapshot: snapshot, settings: settings, now: now)
        XCTAssertNil(second)
    }

    func testWatchRootsIgnoreMissingDirectories() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiquota-watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(UsageSourceWatchRoots.existingPaths(homeURL: home).isEmpty)

        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        XCTAssertEqual(UsageSourceWatchRoots.existingPaths(homeURL: home), [sessions.path])
    }
}
