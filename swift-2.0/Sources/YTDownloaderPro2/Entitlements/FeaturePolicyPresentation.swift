import Foundation

struct FeaturePolicyDenialPresentation: Equatable, Sendable {
    let titleKey: L10n.Key
    let messageKey: L10n.Key

    init(denial: FeatureDenial) {
        titleKey = .featurePolicyDevelopmentTitle
        messageKey = switch denial.reason {
        case .videoHeightRequiresPro:
            .featurePolicyVideoHeightRequiresPro
        case .sourceQualityRequiresPro:
            .featurePolicySourceQualityRequiresPro
        case .unknownVideoHeight:
            .featurePolicyUnknownVideoHeight
        case .batchRequiresPro:
            .featurePolicyBatchRequiresPro
        case .playlistRequiresPro:
            .featurePolicyPlaylistRequiresPro
        case .advancedSubtitlesRequirePro:
            .featurePolicyAdvancedSubtitlesRequiresPro
        case .featureUnavailable:
            .featurePolicyFeatureUnavailable
        case .invalidRequest:
            .featurePolicyInvalidRequest
        }
    }
}
