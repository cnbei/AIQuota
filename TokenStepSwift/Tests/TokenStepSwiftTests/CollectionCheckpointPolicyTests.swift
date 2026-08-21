import Foundation
import XCTest
@testable import TokenStepSwift

final class CollectionCheckpointPolicyTests: XCTestCase {
    func testOnlyManualRefreshForcesFullFileValidation() {
        XCTAssertFalse(CollectionCheckpointPolicy.shouldForceFullValidation(force: false))
        XCTAssertTrue(CollectionCheckpointPolicy.shouldForceFullValidation(force: true))
    }

    func testExpiredCheckpointStillCollectsIncrementally() {
        let now = Date(timeIntervalSince1970: 40_000)
        let state = UsageCollectionState(
            historyDays: 30,
            includesExperimentalAgentSources: false,
            windowDay: "2026-08-21",
            files: [
                UsageCollectionFileState(
                    path: "/tmp/session.jsonl",
                    size: 100,
                    modificationTime: 123
                )
            ]
        )
        let expired = CollectionCheckpoint(
            verifiedAt: now.addingTimeInterval(-CollectionCheckpoint.validationTTL),
            state: state
        )

        XCTAssertFalse(
            CollectionCheckpointPolicy.shouldSkipCollection(
                force: false,
                hasSnapshot: true,
                checkpoint: expired,
                state: state,
                now: now
            )
        )
        XCTAssertFalse(CollectionCheckpointPolicy.shouldForceFullValidation(force: false))
    }
}
