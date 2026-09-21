import Foundation

enum FeatureDecision: Equatable, Sendable {
    case allowed
    case denied(FeatureDenial)

    var denial: FeatureDenial? {
        guard case let .denied(value) = self else { return nil }
        return value
    }
}

struct FeatureDenial: Equatable, Sendable, Identifiable {
    let requiredFeature: FeatureID?
    let reason: FeatureDenialReason
    let canChooseFreeAlternative: Bool

    var id: String {
        "\(reason.rawValue):\(requiredFeature?.rawValue ?? "none")"
    }
}

enum FeatureDenialReason: String, Equatable, Sendable {
    case videoHeightRequiresPro
    case sourceQualityRequiresPro
    case unknownVideoHeight
    case batchRequiresPro
    case playlistRequiresPro
    case advancedSubtitlesRequirePro
    case featureUnavailable
    case invalidRequest
}

enum FeaturePolicyFallbackReason: Equatable, Sendable {
    case unsupportedSchema
}

struct FeaturePolicy: Equatable, Sendable {
    let plan: EntitlementPlan
    let grantedFeatures: Set<FeatureID>
    let videoHeightPolicy: VideoHeightPolicy
    let fallbackReason: FeaturePolicyFallbackReason?

    init(snapshot: EntitlementSnapshot) {
        let accepted: EntitlementSnapshot
        if snapshot.schemaVersion == EntitlementSnapshot.supportedSchemaVersion {
            accepted = snapshot
            fallbackReason = nil
        } else {
            accepted = .syntheticFree
            fallbackReason = .unsupportedSchema
        }
        plan = accepted.plan
        grantedFeatures = accepted.features.intersection(FeatureID.known)
        videoHeightPolicy = accepted.videoHeightPolicy
    }

    func decision(for feature: FeatureID) -> FeatureDecision {
        guard grantedFeatures.contains(feature) else {
            return .denied(FeatureDenial(
                requiredFeature: feature,
                reason: denialReason(for: feature),
                canChooseFreeAlternative: [
                    .videoHD, .videoUHD, .queueBatch, .subtitleAdvanced
                ].contains(feature)
            ))
        }
        return .allowed
    }

    func videoDecision(
        height: Int?,
        isAudioOnly: Bool,
        isSourceQuality: Bool
    ) -> FeatureDecision {
        if isAudioOnly {
            return decision(for: .audioMP3)
        }
        if let height, height <= 0 {
            return invalidRequest()
        }
        if isSourceQuality || (height.map { $0 >= 2_160 } ?? false) {
            return decision(for: .videoUHD)
        }
        if height.map({ $0 > 720 }) == true {
            return decision(for: .videoHD)
        }

        switch videoHeightPolicy {
        case let .limited(limit):
            guard let height else {
                return .denied(FeatureDenial(
                    requiredFeature: .videoHD,
                    reason: .unknownVideoHeight,
                    canChooseFreeAlternative: true
                ))
            }
            guard height <= limit else {
                return decision(for: .videoHD)
            }
            return decision(for: .videoStandard)
        case .unlimited:
            guard height != nil else {
                return decision(for: .videoHD)
            }
            return decision(for: .videoStandard)
        }
    }

    func urlSubmissionDecision(count: Int) -> FeatureDecision {
        guard count > 0 else { return invalidRequest() }
        return decision(for: count == 1 ? .downloadSingle : .queueBatch)
    }

    func playlistExpansionDecision() -> FeatureDecision {
        decision(for: .playlistExpand)
    }

    func subtitleDecision(languageCount: Int, usesAdvancedMode: Bool) -> FeatureDecision {
        guard languageCount >= 0 else { return invalidRequest() }
        return decision(
            for: languageCount <= 1 && !usesAdvancedMode
                ? .subtitleBasic
                : .subtitleAdvanced
        )
    }

    private func denialReason(for feature: FeatureID) -> FeatureDenialReason {
        switch feature {
        case .videoHD:
            .videoHeightRequiresPro
        case .videoUHD:
            .sourceQualityRequiresPro
        case .queueBatch:
            .batchRequiresPro
        case .playlistExpand:
            .playlistRequiresPro
        case .subtitleAdvanced:
            .advancedSubtitlesRequirePro
        default:
            .featureUnavailable
        }
    }

    private func invalidRequest() -> FeatureDecision {
        .denied(FeatureDenial(
            requiredFeature: nil,
            reason: .invalidRequest,
            canChooseFreeAlternative: false
        ))
    }
}

enum FeaturePolicyContext: Equatable, Sendable {
    case publicCompatibility
    case enforced(FeaturePolicy)

    var isEnforced: Bool {
        guard case .enforced = self else { return false }
        return true
    }

    var plan: EntitlementPlan? {
        guard case let .enforced(policy) = self else { return nil }
        return policy.plan
    }

    func decision(for feature: FeatureID) -> FeatureDecision {
        evaluate { $0.decision(for: feature) }
    }

    func videoDecision(
        height: Int?,
        isAudioOnly: Bool,
        isSourceQuality: Bool
    ) -> FeatureDecision {
        evaluate {
            $0.videoDecision(
                height: height,
                isAudioOnly: isAudioOnly,
                isSourceQuality: isSourceQuality
            )
        }
    }

    func urlSubmissionDecision(count: Int) -> FeatureDecision {
        evaluate { $0.urlSubmissionDecision(count: count) }
    }

    func playlistExpansionDecision() -> FeatureDecision {
        evaluate { $0.playlistExpansionDecision() }
    }

    func subtitleDecision(languageCount: Int, usesAdvancedMode: Bool) -> FeatureDecision {
        evaluate {
            $0.subtitleDecision(
                languageCount: languageCount,
                usesAdvancedMode: usesAdvancedMode
            )
        }
    }

    private func evaluate(
        _ decision: (FeaturePolicy) -> FeatureDecision
    ) -> FeatureDecision {
        guard case let .enforced(policy) = self else { return .allowed }
        return decision(policy)
    }
}
