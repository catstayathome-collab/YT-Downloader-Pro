import SwiftUI

struct PlaylistSelectionPresentation: Equatable {
    let analysis: PlaylistAnalysis
    private(set) var selectedIDs: Set<String>

    init(analysis: PlaylistAnalysis) {
        self.analysis = analysis
        selectedIDs = Set(analysis.entries.filter(\.isAvailable).map(\.id))
    }

    var selectedCount: Int { selectedIDs.count }

    mutating func setSelected(_ isSelected: Bool, entryID: String) {
        guard analysis.entries.contains(where: { $0.id == entryID && $0.isAvailable }) else { return }
        if isSelected {
            selectedIDs.insert(entryID)
        } else {
            selectedIDs.remove(entryID)
        }
    }

    mutating func clearSelection() {
        selectedIDs.removeAll()
    }

    mutating func selectAll() {
        selectedIDs = Set(analysis.entries.filter(\.isAvailable).map(\.id))
    }
}

struct PlaylistSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let selectAllToken: UUID
    let onConfirm: (Set<String>, DownloadOptions) -> Void

    @State private var selection: PlaylistSelectionPresentation
    @State private var options: DownloadOptions

    init(
        analysis: PlaylistAnalysis,
        defaults: DownloadOptions,
        selectAllToken: UUID,
        onConfirm: @escaping (Set<String>, DownloadOptions) -> Void
    ) {
        self.selectAllToken = selectAllToken
        self.onConfirm = onConfirm
        _selection = State(initialValue: PlaylistSelectionPresentation(analysis: analysis))
        _options = State(initialValue: defaults.normalizedForExecution())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(MediaFallbackText.localized(selection.analysis.title, locale: locale))
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(L10n.string(.playlistSelectedCount, locale: locale, Int64(selection.selectedCount)))
                        .font(.subheadline)
                        .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                }
                Spacer()
                Button {
                    selection.selectAll()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help(L10n.string(.playlistSelectAll, locale: locale))
                .accessibilityLabel(L10n.string(.playlistSelectAll, locale: locale))
                Button {
                    selection.clearSelection()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help(L10n.string(.playlistClearSelection, locale: locale))
                .accessibilityLabel(L10n.string(.playlistClearSelection, locale: locale))
            }

            List(selection.analysis.entries) { entry in
                Toggle(isOn: entrySelection(entry)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MediaFallbackText.localized(entry.title, locale: locale))
                            .lineLimit(2)
                        if !entry.isAvailable {
                            Text(L10n.string(.playlistEntryUnavailable, locale: locale))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!entry.isAvailable)
                .accessibilityLabel(
                    entry.isAvailable
                        ? L10n.string(.playlistEntrySelect, locale: locale, MediaFallbackText.localized(entry.title, locale: locale))
                        : L10n.string(.playlistEntryUnavailableNamed, locale: locale, MediaFallbackText.localized(entry.title, locale: locale))
                )
            }
            .frame(minHeight: 170, maxHeight: 230)

            Form {
                DownloadOptionsEditor(options: $options, videoChoices: [], audioChoices: [])
            }
            .formStyle(.grouped)
            .frame(minHeight: 210, maxHeight: 250)

            HStack {
                Spacer()
                Button(L10n.string(.commonCancel, locale: locale)) { dismiss() }
                Button(L10n.string(.commonAddSelected, locale: locale)) {
                    onConfirm(selection.selectedIDs, options)
                    dismiss()
                }
                .disabled(selection.selectedIDs.isEmpty || !DownloadOptionsViewState(options: options, locale: locale).canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 640, maxWidth: 720, minHeight: 620)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        .onChange(of: selectAllToken) { _ in
            selection.selectAll()
        }
    }

    private func entrySelection(_ entry: PlaylistEntry) -> Binding<Bool> {
        Binding(
            get: { selection.selectedIDs.contains(entry.id) },
            set: { selection.setSelected($0, entryID: entry.id) }
        )
    }
}
