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
        _options = State(initialValue: defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection.analysis.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("\(selection.selectedCount) selected")
                        .font(.subheadline)
                        .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                }
                Spacer()
                Button {
                    selection.selectAll()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help("Select all available entries")
                .accessibilityLabel("Select all available entries")
                Button {
                    selection.clearSelection()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Clear selection")
                .accessibilityLabel("Clear selection")
            }

            List(selection.analysis.entries) { entry in
                Toggle(isOn: entrySelection(entry)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .lineLimit(2)
                        if !entry.isAvailable {
                            Text(entry.unavailabilityReason ?? "Unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!entry.isAvailable)
                .accessibilityLabel(entry.isAvailable ? "Select \(entry.title)" : "\(entry.title), unavailable")
            }
            .frame(minHeight: 170, maxHeight: 230)

            Form {
                DownloadOptionsEditor(options: $options, videoChoices: [], audioChoices: [])
            }
            .formStyle(.grouped)
            .frame(minHeight: 210, maxHeight: 250)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add Selected") {
                    onConfirm(selection.selectedIDs, options)
                    dismiss()
                }
                .disabled(selection.selectedIDs.isEmpty)
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
