import SwiftUI

struct VideoFormatMenu: View {
    @Environment(\.locale) private var locale

    let title: String
    let emptySelectionLabel: String
    let accesses: [VideoFormatAccess]
    let selectedID: String?
    let onSelect: (String?) -> Void
    let onRequestUpgrade: (FeatureDenial) -> Void

    var body: some View {
        LabeledContent(title) {
            Menu {
                ForEach(accesses) { access in
                    Button {
                        VideoFormatMenuInteraction.activate(
                            access,
                            onSelect: onSelect,
                            onRequestUpgrade: onRequestUpgrade
                        )
                    } label: {
                        rowLabel(for: access)
                    }
                    .accessibilityLabel(access.accessibilityLabel(locale: locale))
                    .help(access.accessibilityLabel(locale: locale))
                }
            } label: {
                currentSelectionLabel
            }
            .menuStyle(.borderlessButton)
            .disabled(accesses.isEmpty)
            .accessibilityLabel(currentAccessibilityLabel)
        }
    }

    @ViewBuilder
    private func rowLabel(for access: VideoFormatAccess) -> some View {
        HStack(spacing: 8) {
            Image(systemName: access.id == selectedID ? "checkmark" : "circle")
                .opacity(access.id == selectedID ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(MediaFormatPresentation.label(for: access.format, locale: locale))
                .lineLimit(2)

            Spacer(minLength: 12)

            if access.denial != nil {
                Image(systemName: "lock.fill")
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(L10n.string(.planProBadge, locale: locale))
                    .frame(width: 30, alignment: .leading)
                    .accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(width: 52, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var currentSelectionLabel: some View {
        HStack(spacing: 8) {
            Text(currentLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)

            if currentAccess?.denial != nil {
                Image(systemName: "lock.fill")
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(L10n.string(.planProBadge, locale: locale))
                    .frame(width: 30, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 260, alignment: .trailing)
    }

    private var currentAccess: VideoFormatAccess? {
        guard let selectedID else { return nil }
        return accesses.first(where: { $0.id == selectedID })
    }

    private var currentLabel: String {
        guard let currentAccess else { return emptySelectionLabel }
        return MediaFormatPresentation.label(for: currentAccess.format, locale: locale)
    }

    private var currentAccessibilityLabel: String {
        currentAccess?.accessibilityLabel(locale: locale) ?? emptySelectionLabel
    }
}
