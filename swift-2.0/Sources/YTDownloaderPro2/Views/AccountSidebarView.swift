import SwiftUI

enum AccountSidebarLayout {
    static let minimumHeight: CGFloat = 56
}

struct DownloadSidebarComposition: Equatable {
    enum Region: Equatable {
        case downloadList(selectionTags: [DownloadStatus.SidebarSection])
        case accountFooter(AccountSidebarPresentation)

        var downloadSelectionTag: DownloadStatus.SidebarSection? {
            switch self {
            case .downloadList, .accountFooter:
                nil
            }
        }
    }

    let regions: [Region]

    static func make(accountPresentation: AccountSidebarPresentation) -> Self {
        var regions: [Region] = [
            .downloadList(selectionTags: DownloadStatus.SidebarSection.allCases)
        ]
        if accountPresentation.isVisible {
            regions.append(.accountFooter(accountPresentation))
        }
        return Self(regions: regions)
    }
}

struct AccountSidebarView: View {
    let presentation: AccountSidebarPresentation

    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                SettingsLink {
                    label
                }
            } else {
                Button {
                    SettingsWindowLauncher.openLegacy()
                } label: {
                    label
                }
            }
        }
        .buttonStyle(.plain)
        .help(L10n.string(.accountSettingsTitle, locale: locale))
        .accessibilityLabel("\(presentation.title), \(presentation.subtitle)")
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: AccountSidebarLayout.minimumHeight, alignment: .leading)
    }

    private var label: some View {
        HStack(spacing: 10) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(presentation.title)
            } else {
                Image(systemName: presentation.systemImage)
                    .font(.title3)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
