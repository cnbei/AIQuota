#if TOKENSTEP_TESTING
import Foundation

@main
enum UsageProbeCheck {
    static func main() throws {
        try testKimiCodeReadsUsageRecordOnly()
        try testGrokCLIReadsInferenceDone()
        try testClineReadsTokensIn()
        try testCherryReadsClaudeUsage()
        try testOpenCodeReadsTokensObject()
        try testSubscriptionNormalizationDropsZeroPrice()
        print("usage-probe-check: ok")
    }

    private static func testKimiCodeReadsUsageRecordOnly() throws {
        let root = try makeTempDir("kimi")
        let folder = root.appendingPathComponent("session_abc/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":4,"inputCacheCreation":2},"usageScope":"turn","time":1717200000000}
        {"type":"context.append_loop_event","event":{"type":"step.end","usage":{"inputOther":10,"output":5,"inputCacheRead":4,"inputCacheCreation":2}},"time":1717200000000}
        """.write(to: folder.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            kimiCodeRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        try expect(snapshot.sources["Kimi Code"]?.status == "ok", "kimi status")
        try expect(snapshot.sources["Kimi Code"]?.records == 1, "kimi deduped to one record")
        try expect(snapshot.totals.tokens == 21, "kimi tokens got \(snapshot.totals.tokens)")
    }

    private static func testGrokCLIReadsInferenceDone() throws {
        let folder = try makeTempDir("grok")
        let log = folder.appendingPathComponent("unified.jsonl")
        try """
        {"ts":"2026-07-18T13:16:52.825Z","sid":"s1","msg":"shell.turn.inference_done","ctx":{"loop_index":1,"prompt_tokens":100,"cached_prompt_tokens":40,"completion_tokens":20,"reasoning_tokens":5}}
        {"ts":"2026-07-18T13:16:01.787Z","sid":"s1","msg":"AuthManager::new","ctx":{}}
        """.write(to: log, atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            grokUnifiedLogURLs: [log]
        )
        try expect(snapshot.sources["Grok Build"]?.status == "ok", "grok status")
        try expect(snapshot.totals.tokens == 120, "grok tokens")
    }

    private static func testClineReadsTokensIn() throws {
        let root = try makeTempDir("cline")
        let task = root.appendingPathComponent("task-1", isDirectory: true)
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true)
        try """
        [{"ts":1717200000000,"say":"api_req_started","text":"{\\"tokensIn\\":30,\\"tokensOut\\":10,\\"cacheWrites\\":2,\\"cacheReads\\":4}"}]
        """.write(to: task.appendingPathComponent("ui_messages.json"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            clineRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        try expect(snapshot.sources["Cline"]?.status == "ok", "cline status")
        try expect(snapshot.totals.tokens == 46, "cline tokens")
    }

    private static func testCherryReadsClaudeUsage() throws {
        let root = try makeTempDir("cherry")
        let project = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        {"timestamp":1717200000000,"message":{"id":"m1","model":"claude-sonnet","usage":{"input_tokens":20,"output_tokens":8}}}
        """.write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            cherryRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        try expect(snapshot.sources["Cherry Studio"]?.status == "ok", "cherry status")
        try expect(snapshot.totals.tokens == 28, "cherry tokens")
    }

    private static func testOpenCodeReadsTokensObject() throws {
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
        try expect(snapshot.sources["OpenCode"]?.status == "ok", "opencode status")
        try expect(snapshot.totals.tokens == 20, "opencode tokens")
    }

    private static func testSubscriptionNormalizationDropsZeroPrice() throws {
        let plans = SubscriptionPlan.normalized([
            SubscriptionPlan(provider: .cursor, monthlyPrice: 20, renewalDay: 40),
            SubscriptionPlan(provider: .kimi, monthlyPrice: 0, renewalDay: 1)
        ])
        try expect(plans.count == 1, "zero price dropped")
        try expect(plans.first?.renewalDay == 28, "renewal day clamped")
    }

    private static func makeTempDir(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiquota-probe-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "UsageProbeCheck", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
#endif
