import Foundation

enum UpgradePresentationRoute: Equatable, Identifiable, Sendable {
    case lockedQuality(FeatureDenialReason)
    case batchInput
    case playlistExpansion
    case advancedSubtitles
    case restrictedJob(feature: FeatureID, reason: FeatureDenialReason)
    case settings

    init(denial: FeatureDenial) {
        switch denial.reason {
        case .videoHeightRequiresPro, .sourceQualityRequiresPro, .unknownVideoHeight:
            self = .lockedQuality(denial.reason)
        case .batchRequiresPro:
            self = .batchInput
        case .playlistRequiresPro:
            self = .playlistExpansion
        case .advancedSubtitlesRequirePro:
            self = .advancedSubtitles
        case .featureUnavailable, .invalidRequest:
            self = .restrictedJob(
                feature: denial.requiredFeature ?? FeatureID(rawValue: "unavailable"),
                reason: denial.reason
            )
        }
    }

    init(requirement: DownloadAccessRequirement) {
        self = .restrictedJob(feature: requirement.feature, reason: requirement.reason)
    }

    var id: String {
        switch self {
        case let .lockedQuality(reason): "locked-quality:\(reason.rawValue)"
        case .batchInput: "batch-input"
        case .playlistExpansion: "playlist-expansion"
        case .advancedSubtitles: "advanced-subtitles"
        case let .restrictedJob(feature, reason): "restricted-job:\(feature.rawValue):\(reason.rawValue)"
        case .settings: "settings"
        }
    }

    fileprivate var reasonKey: L10n.Key {
        switch self {
        case .lockedQuality: .planComparisonReasonLockedQuality
        case .batchInput: .planComparisonReasonBatch
        case .playlistExpansion: .planComparisonReasonPlaylist
        case .advancedSubtitles: .planComparisonReasonAdvancedSubtitles
        case .restrictedJob: .planComparisonReasonRestrictedJob
        case .settings: .planComparisonReasonSettings
        }
    }
}

struct PlanSettingsPresentation: Equatable, Sendable {
    let plan: AppPlan

    func planName(locale: Locale) -> String {
        plan.localizedName(locale: locale)
    }

    func qualityAccess(locale: Locale) -> String {
        L10n.string(plan == .free ? .planQualityFree : .planQualityPro, locale: locale)
    }
}

enum PlanComparisonRowID: Equatable, Sendable {
    case quality
    case urlInput
    case playlist
    case subtitles
    case history
    case support
}

struct LocalizedPlanComparisonRow: Equatable, Sendable {
    let id: PlanComparisonRowID
    let title: String
    let freeValue: String
    let proValue: String
}

enum PlanComparisonAction: Equatable, Sendable {
    case close
}

struct PlanComparisonPresentation: Equatable, Sendable {
    let currentPlan: AppPlan
    let route: UpgradePresentationRoute

    var actions: [PlanComparisonAction] { [.close] }
    var externalURL: URL? { nil }

    func reason(locale: Locale) -> String {
        L10n.string(route.reasonKey, locale: locale)
    }

    func unavailableMessage(locale: Locale) -> String {
        L10n.string(.planComparisonUnavailable, locale: locale)
    }

    func localizedRows(locale: Locale) -> [LocalizedPlanComparisonRow] {
        [
            row(.quality, .planComparisonRowQuality, .planQualityFree, .planQualityPro, locale: locale),
            row(.urlInput, .planComparisonRowURLInput, .planComparisonValueSingleURL, .planComparisonValueBatchURLs, locale: locale),
            row(.playlist, .planComparisonRowPlaylist, .planComparisonValuePlaylistUnavailable, .planComparisonValuePlaylistExpansion, locale: locale),
            row(.subtitles, .planComparisonRowSubtitles, .planComparisonValueBasicSubtitles, .planComparisonValueAdvancedSubtitles, locale: locale),
            row(.history, .planComparisonRowHistory, .planComparisonValueLocalHistory, .planComparisonValueHistorySync, locale: locale),
            row(.support, .planComparisonRowSupport, .planComparisonValueStandardSupport, .planComparisonValuePrioritySupport, locale: locale)
        ]
    }

    private func row(
        _ id: PlanComparisonRowID,
        _ titleKey: L10n.Key,
        _ freeKey: L10n.Key,
        _ proKey: L10n.Key,
        locale: Locale
    ) -> LocalizedPlanComparisonRow {
        LocalizedPlanComparisonRow(
            id: id,
            title: L10n.string(titleKey, locale: locale),
            freeValue: L10n.string(freeKey, locale: locale),
            proValue: L10n.string(proKey, locale: locale)
        )
    }
}

enum VideoFormatAccess: Equatable, Sendable, Identifiable {
    case allowed(MediaFormat)
    case locked(MediaFormat, FeatureDenial)

    var id: String { format.id }

    var format: MediaFormat {
        switch self {
        case let .allowed(format), let .locked(format, _):
            format
        }
    }

    var denial: FeatureDenial? {
        guard case let .locked(_, denial) = self else { return nil }
        return denial
    }

    var isAllowed: Bool { denial == nil }

    func leadingSystemImage(isSelected: Bool) -> String? {
        if isSelected { return "checkmark" }
        return denial == nil ? nil : "lock.fill"
    }

    func accessibilityLabel(locale: Locale) -> String {
        let quality = MediaFormatPresentation.label(for: format, locale: locale)
        guard denial != nil else { return quality }
        return "\(quality), \(L10n.string(.planRequiresPro, locale: locale))"
    }
}

struct VideoFormatMenuPresentation: Equatable, Sendable {
    let accesses: [VideoFormatAccess]
    let selectedID: String?

    init(
        formats: [MediaFormat],
        selectedID: String?,
        outputKind: OutputKind,
        featurePolicy: FeaturePolicyContext
    ) {
        accesses = formats.map { format in
            var candidate = DownloadOptions.defaults
            candidate.selectOutputKind(outputKind)
            candidate.selectVideoFormat(format)
            return switch candidate.featurePolicyDecision(in: featurePolicy) {
            case .allowed:
                .allowed(format)
            case let .denied(denial):
                .locked(format, denial)
            }
        }

        if let selectedID, formats.contains(where: { $0.id == selectedID }) {
            self.selectedID = selectedID
        } else {
            self.selectedID = accesses.first(where: \.isAllowed)?.id
        }
    }

    var highestAllowedID: String? {
        accesses.first(where: \.isAllowed)?.id
    }

    func selectionReconciliation() -> VideoFormatSelectionReconciliation {
        guard let selectedID,
              let selectedAccess = accesses.first(where: { $0.id == selectedID }),
              !selectedAccess.isAllowed else {
            return VideoFormatSelectionReconciliation(
                selectedID: selectedID,
                didNormalize: false
            )
        }
        return VideoFormatSelectionReconciliation(
            selectedID: highestAllowedID,
            didNormalize: true
        )
    }
}

struct VideoFormatSelectionReconciliation: Equatable, Sendable {
    let selectedID: String?
    let didNormalize: Bool
}

enum VideoFormatMenuInteraction {
    static func activate(
        _ access: VideoFormatAccess,
        onSelect: (String?) -> Void,
        onRequestUpgrade: (FeatureDenial) -> Void
    ) {
        switch access {
        case let .allowed(format):
            onSelect(format.id)
        case let .locked(_, denial):
            onRequestUpgrade(denial)
        }
    }
}
