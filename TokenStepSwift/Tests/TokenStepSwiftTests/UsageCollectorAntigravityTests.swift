import Foundation
import XCTest
@testable import TokenStepSwift

final class UsageCollectorAntigravityTests: XCTestCase {
    func testParsesOfficialUsageAndModelFromGenMetadata() throws {
        let root = try makeConversationRoot(
            sessionID: "session-a",
            blobs: [
                AntigravityProto.encodeGenMetadata(
                    model: "gemini-3.7-flash",
                    system: 1_132,
                    newInput: 500,
                    cacheRead: 16_000,
                    output: 300,
                    thinking: 40,
                    responseID: "resp-1",
                    timestamp: 1_717_200_000
                )
            ],
            sessionCreated: 1_717_200_000
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(antigravityRootURLs: [root])

        XCTAssertEqual(snapshot.sources["Antigravity"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Antigravity"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 17_972)
        XCTAssertEqual(snapshot.daily.first?.tools["Antigravity"], 17_972)
        XCTAssertEqual(snapshot.daily.first?.models["gemini-3.7-flash"], 17_972)
        XCTAssertEqual(snapshot.daily.first?.modelsByTool["Antigravity"]?["gemini-3.7-flash"], 17_972)

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.totalTokens, 17_972)
        XCTAssertEqual(work.modelRequestCount, 1)
        XCTAssertEqual(work.sources.first?.source, "Antigravity")
        XCTAssertEqual(work.inputTokens, 17_632)
        XCTAssertEqual(work.cachedInputTokens, 16_000)
        XCTAssertEqual(work.outputTokens, 340)
    }

    func testDedupesByResponseIdAndSkipsEmptyUsage() throws {
        let root = try makeConversationRoot(
            sessionID: "session-b",
            blobs: [
                AntigravityProto.encodeGenMetadata(
                    model: "gemini-3.7-flash",
                    system: 10,
                    newInput: 20,
                    output: 5,
                    thinking: 1,
                    responseID: "same"
                ),
                AntigravityProto.encodeGenMetadata(
                    model: "gemini-3.7-flash",
                    system: 99,
                    newInput: 99,
                    output: 99,
                    thinking: 99,
                    responseID: "same"
                ),
                AntigravityProto.encodeGenMetadata(
                    model: "gemini-3.7-flash",
                    responseID: "empty"
                )
            ],
            sessionCreated: 1_717_200_000
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(antigravityRootURLs: [root])
        XCTAssertEqual(snapshot.sources["Antigravity"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 36)
    }

    func testRecoversModelFromSiblingRowWhenResponseModelIsMissing() throws {
        let root = try makeConversationRoot(
            sessionID: "session-c",
            blobs: [
                AntigravityProto.encodeGenMetadata(
                    model: "gemini-3.7-flash",
                    display: "Gemini 3.7 Flash",
                    system: 10,
                    newInput: 10,
                    output: 2,
                    responseID: "named"
                ),
                AntigravityProto.encodeGenMetadata(
                    display: "Gemini 3.7 Flash",
                    system: 10,
                    newInput: 10,
                    output: 2,
                    responseID: "unnamed"
                )
            ],
            sessionCreated: 1_717_200_000
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(antigravityRootURLs: [root])
        XCTAssertEqual(snapshot.sources["Antigravity"]?.records, 2)
        XCTAssertEqual(snapshot.daily.first?.models["gemini-3.7-flash"], 44)
        XCTAssertNil(snapshot.daily.first?.models["unknown"])
    }

    func testCollectionStateIncludesAntigravityWithoutExperimentalFlag() throws {
        let home = try makeTempDir("agy-home")
        let conversations = home.appendingPathComponent(
            ".gemini/antigravity-cli/conversations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        try Data().write(to: conversations.appendingPathComponent("session.db"))

        let state = UsageCollector.collectionState(
            historyDays: 30,
            includeExperimentalAgentSources: false,
            homeURL: home
        )
        XCTAssertTrue(state.files.contains(where: { $0.path.hasSuffix("session.db") }))
    }

    func testParserReadsHexAndSessionTimestamp() throws {
        let blob = AntigravityProto.encodeGenMetadata(
            model: "gemini-3.7-flash",
            system: 8,
            newInput: 2,
            output: 3,
            thinking: 1,
            responseID: "hex-1"
        )
        let hex = blob.map { String(format: "%02X", $0) }.joined()
        let data = try XCTUnwrap(AntigravityUsageParser.data(fromHex: hex))
        let trajectory = AntigravityProto.encodeTrajectory(created: 1_717_203_600)
        let turns = AntigravityUsageParser.turns(
            fromGenMetadataBlobs: [data],
            sessionCreatedEpoch: AntigravityUsageParser.sessionCreatedEpoch(fromTrajectoryBlob: trajectory)
        )
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.model, "gemini-3.7-flash")
        XCTAssertEqual(turns.first?.inputTokens, 10)
        XCTAssertEqual(turns.first?.outputTokens, 4)
        XCTAssertEqual(turns.first?.reasoningTokens, 1)
        XCTAssertEqual(turns.first?.timestampEpoch, 1_717_203_600)
    }

    private func makeConversationRoot(
        sessionID: String,
        blobs: [Data],
        sessionCreated: Int
    ) throws -> URL {
        let root = try makeTempDir("agy-\(sessionID)")
        let database = root.appendingPathComponent("\(sessionID).db")
        var inserts = [
            """
            create table gen_metadata (idx integer, data blob, size integer not null default 0);
            create table trajectory_metadata_blob (id text default 'main', data blob);
            insert into trajectory_metadata_blob (id, data) values ('main', x'\(AntigravityProto.encodeTrajectory(created: sessionCreated).hexString)');
            """
        ]
        for (index, blob) in blobs.enumerated() {
            inserts.append(
                "insert into gen_metadata (idx, data, size) values (\(index), x'\(blob.hexString)', \(blob.count));"
            )
        }
        try runSQLite(database: database, sql: inserts.joined(separator: "\n"))
        return root
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = Pipe()
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "sqlite fixture failed"
            throw NSError(domain: "UsageCollectorAntigravityTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}

private enum AntigravityProto {
    static func encodeGenMetadata(
        model: String? = nil,
        display: String? = nil,
        system: UInt64 = 0,
        newInput: UInt64 = 0,
        cacheRead: UInt64 = 0,
        output: UInt64 = 0,
        thinking: UInt64 = 0,
        responseID: String,
        timestamp: UInt64? = nil
    ) -> Data {
        var usage = Data()
        if system > 0 { usage.append(encVarint(1, system)) }
        if newInput > 0 { usage.append(encVarint(2, newInput)) }
        if cacheRead > 0 { usage.append(encVarint(5, cacheRead)) }
        if output > 0 { usage.append(encVarint(9, output)) }
        if thinking > 0 { usage.append(encVarint(10, thinking)) }
        usage.append(encLen(11, Data(responseID.utf8)))

        var chat = Data()
        chat.append(encLen(4, usage))
        if let timestamp {
            var stamp = Data()
            stamp.append(encVarint(1, timestamp))
            stamp.append(encVarint(2, 0))
            var gen = Data()
            gen.append(encLen(4, stamp))
            chat.append(encLen(9, gen))
        }
        if let model {
            chat.append(encLen(19, Data(model.utf8)))
        }
        if let display {
            chat.append(encLen(21, Data(display.utf8)))
        }
        return encLen(1, chat)
    }

    static func encodeTrajectory(created: Int) -> Data {
        var stamp = Data()
        stamp.append(encVarint(1, UInt64(created)))
        stamp.append(encVarint(2, 0))
        return encLen(2, stamp)
    }

    private static func encVarint(_ field: UInt64, _ value: UInt64) -> Data {
        var out = encodeVarint(field << 3)
        out.append(encodeVarint(value))
        return out
    }

    private static func encLen(_ field: UInt64, _ payload: Data) -> Data {
        var out = encodeVarint((field << 3) | 2)
        out.append(encodeVarint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
