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

    func testFreeVideoBoundaryAllows720AndDeniesUnknownOrHigherVideo() {
        let policy = FeaturePolicy(snapshot: .syntheticFree)

        XCTAssertEqual(policy.videoDecision(height: 720, isAudioOnly: false, isSourceQuality: false), .allowed)
        XCTAssertEqual(
            policy.videoDecision(height: 721, isAudioOnly: false, isSourceQuality: false).denial?.reason,
            .videoHeightRequiresPro
        )
        XCTAssertEqual(
            policy.videoDecision(height: nil, isAudioOnly: false, isSourceQuality: false).denial?.reason,
            .unknownVideoHeight
        )
        XCTAssertEqual(policy.videoDecision(height: nil, isAudioOnly: true, isSourceQuality: false), .allowed)
    }

    func testProVideoPolicyAllowsHDSourceAndUnknownVideoHeight() {
        let policy = FeaturePolicy(snapshot: .syntheticPro)

        XCTAssertEqual(policy.videoDecision(height: 1080, isAudioOnly: false, isSourceQuality: false), .allowed)
        XCTAssertEqual(policy.videoDecision(height: 2160, isAudioOnly: false, isSourceQuality: false), .allowed)
        XCTAssertEqual(policy.videoDecision(height: nil, isAudioOnly: false, isSourceQuality: true), .allowed)
        XCTAssertEqual(policy.videoDecision(height: nil, isAudioOnly: false, isSourceQuality: false), .allowed)
    }

    func testFreeAndProURLPlaylistSubtitleRetryAndHistoryMatrix() {
        let free = FeaturePolicy(snapshot: .syntheticFree)
        let pro = FeaturePolicy(snapshot: .syntheticPro)

        XCTAssertEqual(free.urlSubmissionDecision(count: 1), .allowed)
        XCTAssertEqual(free.urlSubmissionDecision(count: 2).denial?.requiredFeature, .queueBatch)
        XCTAssertEqual(free.urlSubmissionDecision(count: 0).denial?.reason, .invalidRequest)
        XCTAssertEqual(free.playlistExpansionDecision().denial?.requiredFeature, .playlistExpand)
        XCTAssertEqual(pro.urlSubmissionDecision(count: 10), .allowed)
        XCTAssertEqual(pro.playlistExpansionDecision(), .allowed)
        XCTAssertEqual(free.subtitleDecision(languageCount: 1, usesAdvancedMode: false), .allowed)
        XCTAssertEqual(
            free.subtitleDecision(languageCount: 2, usesAdvancedMode: false).denial?.requiredFeature,
            .subtitleAdvanced
        )
        XCTAssertEqual(free.subtitleDecision(languageCount: -1, usesAdvancedMode: false).denial?.reason, .invalidRequest)
        XCTAssertEqual(free.decision(for: .recoveryManual), .allowed)
        XCTAssertEqual(free.decision(for: .recoveryFull).denial?.requiredFeature, .recoveryFull)
        XCTAssertEqual(free.decision(for: .historyLocal), .allowed)
        XCTAssertEqual(free.decision(for: .historySync).denial?.requiredFeature, .historySync)
        XCTAssertEqual(free.decision(for: .formatPresets).denial?.requiredFeature, .formatPresets)
        XCTAssertEqual(free.decision(for: .supportStandard), .allowed)
        XCTAssertEqual(free.decision(for: .supportPriority).denial?.requiredFeature, .supportPriority)
    }

    func testUnsupportedSchemaAndUnknownFeaturesFallBackToFree() {
        let snapshot = EntitlementSnapshot(
            schemaVersion: 99,
            plan: .pro,
            features: FeatureID.known.union([FeatureID(rawValue: "future.capability")]),
            videoHeightPolicy: .unlimited,
            subscriptionState: .active
        )
        let policy = FeaturePolicy(snapshot: snapshot)

        XCTAssertEqual(policy.fallbackReason, .unsupportedSchema)
        XCTAssertEqual(
            policy.videoDecision(height: 1080, isAudioOnly: false, isSourceQuality: false).denial?.requiredFeature,
            .videoHD
        )
        XCTAssertFalse(policy.grantedFeatures.contains(FeatureID(rawValue: "future.capability")))
    }

    func testUnknownFeatureOnSupportedSchemaDoesNotGrantAccess() {
        let unknown = FeatureID(rawValue: "future.capability")
        let snapshot = EntitlementSnapshot(
            schemaVersion: EntitlementSnapshot.supportedSchemaVersion,
            plan: .free,
            features: EntitlementSnapshot.syntheticFree.features.union([unknown]),
            videoHeightPolicy: .limited(720),
            subscriptionState: .none
        )
        let policy = FeaturePolicy(snapshot: snapshot)

        XCTAssertFalse(policy.grantedFeatures.contains(unknown))
        XCTAssertEqual(policy.decision(for: unknown).denial?.reason, .featureUnavailable)
    }

    func testPublicCompatibilityAllowsWithoutPretendingToBePro() {
        let context = FeaturePolicyContext.publicCompatibility

        XCTAssertFalse(context.isEnforced)
        XCTAssertNil(context.plan)
        XCTAssertEqual(context.urlSubmissionDecision(count: 5), .allowed)
        XCTAssertEqual(
            context.videoDecision(height: nil, isAudioOnly: false, isSourceQuality: true),
            .allowed
        )
    }
}
