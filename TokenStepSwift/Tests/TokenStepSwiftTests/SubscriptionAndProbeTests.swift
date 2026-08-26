import Foundation
import XCTest
@testable import TokenStepSwift

final class SubscriptionAndProbeTests: XCTestCase {
    func testSubscriptionSummaryUsesCurrentMonthCosts() {
        let snapshot = UsageSnapshot(
            generatedAt: "2026-08-21T00:00:00Z",
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 20, cost: 13, activeDays: 2),
            daily: [
                DailyUsage(
                    date: "2026-07-01",
                    tools: ["Codex": 10],
                    totalTokens: 10,
                    cost: 9,
                    toolCosts: ["Codex": 9]
                ),
                DailyUsage(
                    date: "2026-08-10",
                    tools: ["Codex": 4, "Claude Code": 6],
                    totalTokens: 10,
                    cost: 4,
                    toolCosts: ["Codex": 1.5, "Claude Code": 2.5]
                )
            ],
            tools: [],
            models: [],
            sources: [:]
        )
        let summary = SubscriptionLedger.summary(
            plans: [
                SubscriptionPlan(provider: .codex, monthlyPrice: 20, renewalDay: 1),
                SubscriptionPlan(provider: .claude, monthlyPrice: 20, renewalDay: 1)
            ],
            snapshot: snapshot,
            now: date("2026-08-21")
        )
        XCTAssertEqual(summary.estimatedCostUSD, 4, accuracy: 0.000_1)
        XCTAssertEqual(summary.planAmount, 40, accuracy: 0.000_1)
        XCTAssertEqual(summary.currency, .usd)
        XCTAssertEqual(summary.planCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.ratio), 0.1, accuracy: 0.000_1)

        let cursor = SubscriptionLedger.providerSummary(
            provider: .codex,
            plans: [SubscriptionPlan(provider: .codex, monthlyPrice: 20, renewalDay: 8)],
            snapshot: snapshot,
            now: date("2026-08-21")
        )
        XCTAssertEqual(try XCTUnwrap(cursor?.estimatedCostUSD), 1.5, accuracy: 0.000_1)
    }

    func testCNYPlanConvertsEstimateWithFixedRate() {
        let snapshot = UsageSnapshot(
            generatedAt: "2026-08-21T00:00:00Z",
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 10, cost: 4, activeDays: 1),
            daily: [
                DailyUsage(
                    date: "2026-08-10",
                    tools: ["Kimi Code": 10],
                    totalTokens: 10,
                    cost: 4,
                    toolCosts: ["Kimi Code": 4]
                )
            ],
            tools: [],
            models: [],
            sources: [:]
        )
        let summary = SubscriptionLedger.providerSummary(
            provider: .kimi,
            plans: [SubscriptionPlan(provider: .kimi, monthlyPrice: 199, renewalDay: 1, currency: .cny)],
            snapshot: snapshot,
            now: date("2026-08-21")
        )
        XCTAssertEqual(try XCTUnwrap(summary?.currency), .cny)
        XCTAssertEqual(try XCTUnwrap(summary?.planAmount), 199, accuracy: 0.000_1)
        XCTAssertEqual(
            try XCTUnwrap(summary?.ratio),
            (4 * SubscriptionLedger.usdToCny) / 199,
            accuracy: 0.000_1
        )
        XCTAssertTrue(try XCTUnwrap(summary?.estimatedText).contains("¥"))
    }

    func testLegacySubscriptionJSONDefaultsToUSD() throws {
        let json = """
        {"provider":"cursor","monthly_price":20,"renewal_day":8}
        """.data(using: .utf8)!
        let plan = try JSONDecoder().decode(SubscriptionPlan.self, from: json)
        XCTAssertEqual(plan.currency, .usd)
        XCTAssertEqual(plan.monthlyPrice, 20)
    }

    func testKimiCodeCollectorReadsUsageRecordOnly() throws {
        let root = try makeTempDir("kimi-code")
        let file = root
            .appendingPathComponent("session_abc/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try """
        {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":4,"inputCacheCreation":2},"usageScope":"turn","time":1717200000000}
        {"type":"context.append_loop_event","event":{"type":"step.end","usage":{"inputOther":10,"output":5,"inputCacheRead":4,"inputCacheCreation":2},"messageId":"dup"},"time":1717200000000}
        {"type":"config.update","systemPrompt":"must not be parsed"}
        """.write(to: file.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            kimiCodeRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(snapshot.sources["Kimi Code"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Kimi Code"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 21)
        XCTAssertEqual(snapshot.daily.first?.tools["Kimi Code"], 21)
        XCTAssertEqual(snapshot.daily.first?.models["kimi-code/k3"], 21)
    }

    func testGrokCLICollectorReadsInferenceDone() throws {
        let folder = try makeTempDir("grok-cli")
        let log = folder.appendingPathComponent("unified.jsonl")
        try """
        {"ts":"2026-07-18T13:16:52.825Z","sid":"s1","msg":"shell.turn.inference_done","ctx":{"loop_index":1,"prompt_tokens":100,"cached_prompt_tokens":40,"completion_tokens":20,"reasoning_tokens":5}}
        {"ts":"2026-07-18T13:16:01.787Z","sid":"s1","msg":"AuthManager::new","ctx":{"token":"secret"}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            grokUnifiedLogURLs: [log]
        )
        XCTAssertEqual(snapshot.sources["Grok Build"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Grok Build"]?.records, 1)
        XCTAssertEqual(snapshot.daily.first?.tools["Grok Build"], 120)
        XCTAssertEqual(snapshot.totals.tokens, 120)
    }

    func testCollectionStateIncludesGrokLogWithoutExperimentalFlag() throws {
        let home = try makeTempDir("grok-home")
        let log = home.appendingPathComponent(".grok/logs/unified.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)

        let state = UsageCollector.collectionState(
            historyDays: 30,
            includeExperimentalAgentSources: false,
            homeURL: home
        )
        XCTAssertTrue(state.files.contains(where: { $0.path == log.path }))
    }

    func testCollectionStateIncludesAntigravityWithoutExperimentalFlag() throws {
        let home = try makeTempDir("agy-home")
        let db = home.appendingPathComponent(".gemini/antigravity-cli/conversations/session.db")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: db)

        let state = UsageCollector.collectionState(
            historyDays: 30,
            includeExperimentalAgentSources: false,
            homeURL: home
        )
        XCTAssertTrue(state.files.contains(where: { $0.path == db.path }))
    }

    func testCollectionStateIncludesWorkBuddyWithoutExperimentalFlag() throws {
        let home = try makeTempDir("workbuddy-home")
        let session = home.appendingPathComponent(
            ".workbuddy/projects/example/session.jsonl"
        )
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: session)

        let state = UsageCollector.collectionState(
            historyDays: 30,
            includeExperimentalAgentSources: false,
            homeURL: home
        )
        XCTAssertTrue(state.files.contains(where: { $0.path == session.path }))
    }

    func testClineCollectorReadsTokensInWithoutMessageText() throws {
        let root = try makeTempDir("cline")
        let task = root.appendingPathComponent("task-1", isDirectory: true)
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        try """
        [{"ts":1717200000000,"say":"api_req_started","text":"{\\"tokensIn\\":30,\\"tokensOut\\":10,\\"cacheWrites\\":2,\\"cacheReads\\":4,\\"request\\":\\"must not be stored\\"}"},{"ts":1717203600000,"say":"text","text":"hello"}]
        """.write(to: task.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            clineRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(snapshot.sources["Cline"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Cline"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 46)
    }

    func testCherryStudioCollectorReadsClaudeShapedUsage() throws {
        let root = try makeTempDir("cherry")
        let project = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        {"timestamp":1717200000000,"message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":20,"output_tokens":8},"content":"must not be parsed"}}
        {"timestamp":1717203600000,"type":"user","message":{"content":"no usage"}}
        """.write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            cherryRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(snapshot.sources["Cherry Studio"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Cherry Studio"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 28)
        XCTAssertEqual(snapshot.daily.first?.models["claude-sonnet"], 28)
    }

    func testOpenCodeCollectorReadsTokensObject() throws {
        let root = try makeTempDir("opencode")
        let message = root.appendingPathComponent("storage/message", isDirectory: true)
        try FileManager.default.createDirectory(at: message, withIntermediateDirectories: true)
        try """
        {"id":"m1","sessionID":"s1","time":{"created":1717200000},"model":"gpt-4","tokens":{"input":15,"output":5,"reasoning":1,"cache":{"read":3,"write":1}}}
        """.write(to: message.appendingPathComponent("m1.json"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            openCodeRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(snapshot.sources["OpenCode"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["OpenCode"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 20)
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStep-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
