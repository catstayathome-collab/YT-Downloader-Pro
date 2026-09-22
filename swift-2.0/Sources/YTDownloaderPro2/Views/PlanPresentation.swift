import Foundation

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

    func accessibilityLabel(locale: Locale) -> String {
        let quality = MediaFormatPresentation.label(for: format, locale: locale)
        guard let denial else { return quality }
        let denialPresentation = FeaturePolicyDenialPresentation(denial: denial)
        return "\(quality), \(L10n.string(denialPresentation.messageKey, locale: locale))"
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
