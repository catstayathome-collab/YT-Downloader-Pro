import XCTest
@testable import YTDownloaderPro2

final class FeaturePolicyTests: XCTestCase {
    func testFeatureIdentifiersUseStableSerializedValues() throws {
        XCTAssertEqual(FeatureID.downloadSingle.rawValue, "download.single")
        XCTAssertEqual(FeatureID.videoHD.rawValue, "video.hd")
        XCTAssertEqual(FeatureID.queueBatch.rawValue, "queue.batch")
        XCTAssertEqual(FeatureID.supportPriority.rawValue, "support.priority")
        XCTAssertEqual(
            try JSONDecoder().decode(FeatureID.self, from: Data("\"future.capability\"".utf8)),
            FeatureID(rawValue: "future.capability")
        )
    }

    func testSyntheticFreeSnapshotContainsOnlyApprovedFreeCapabilities() {
        let snapshot = EntitlementSnapshot.syntheticFree

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.plan, .free)
        XCTAssertEqual(snapshot.videoHeightPolicy, .limited(720))
        XCTAssertTrue(snapshot.features.contains(.downloadSingle))
        XCTAssertTrue(snapshot.features.contains(.audioMP3))
        XCTAssertTrue(snapshot.features.contains(.subtitleBasic))
        XCTAssertTrue(snapshot.features.contains(.historyLocal))
        XCTAssertFalse(snapshot.features.contains(.queueBatch))
        XCTAssertFalse(snapshot.features.contains(.playlistExpand))
        XCTAssertFalse(snapshot.features.contains(.videoHD))
    }

    func testSyntheticProSnapshotContainsEveryKnownCapability() {
        XCTAssertEqual(EntitlementSnapshot.syntheticPro.plan, .pro)
        XCTAssertEqual(EntitlementSnapshot.syntheticPro.videoHeightPolicy, .unlimited)
        XCTAssertEqual(EntitlementSnapshot.syntheticPro.features, FeatureID.known)
    }
}
