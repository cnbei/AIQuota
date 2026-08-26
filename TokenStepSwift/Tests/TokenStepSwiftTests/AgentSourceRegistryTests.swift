import XCTest
@testable import TokenStepSwift

final class AgentSourceRegistryTests: XCTestCase {
    func testKnownToolsResolveWithoutHardcodedSwitch() {
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Codex")?.id, "codex")
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Claude Code")?.id, "claude")
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "zcode")?.displayName, "ZCode")
        XCTAssertEqual(AgentSourceRegistry.displayName(for: "hermes"), "Hermes Agent")
        XCTAssertEqual(AgentSourceRegistry.displayName(for: "workbuddy"), "WorkBuddy")
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "WorkBuddy")?.isExperimental, false)
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Kimi Code")?.id, "kimi-code")
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Grok CLI")?.tier, .ledger)
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Grok CLI")?.displayName, "Grok Build")
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Grok Build")?.isExperimental, false)
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Antigravity CLI")?.displayName, "Antigravity")
        XCTAssertEqual(AgentSourceRegistry.descriptor(for: "Antigravity")?.isExperimental, false)
        XCTAssertTrue(AgentSourceRegistry.ledgerSources.contains(where: { $0.id == "opencode" && $0.isExperimental }))
    }

    func testLedgerSourcesDoNotIncludeQuotaOrSignalTiers() {
        XCTAssertTrue(AgentSourceRegistry.ledgerSources.allSatisfy { $0.tier == .ledger })
        XCTAssertTrue(AgentSourceRegistry.quotaSources.contains(where: { $0.id == "cursor" }))
        XCTAssertTrue(AgentSourceRegistry.signalSources.contains(where: { $0.id == "cursor-code" }))
    }

    func testUniqueToolNamesFallbackUsesRegistry() {
        let names = uniqueToolNames(in: [])
        XCTAssertEqual(names, AgentSourceRegistry.defaultLegendNames)
    }
}
