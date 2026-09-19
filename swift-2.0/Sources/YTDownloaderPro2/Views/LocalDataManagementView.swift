import AppKit
import SwiftUI

struct LocalDataExportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DownloadStore

    let appVersion: String
    let releaseChannel: String

    @State private var draft: LocalDataExportDraft?
    @State private var isPreparing = false
    @State private var feedback: LocalDataFeedback?
    @State private var exportedPackageURL: URL?

    private let writer = LocalExportPackageWriter()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeader(title: "Export Local App Data")

            Text("Review the sanitized counts below before creating a local export package. Nothing is uploaded or sent automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Sanitized Export Preview") {
                if let draft {
                    let presentation = LocalExportPreviewPresentation(draft: draft)
                    VStack(spacing: 10) {
                        exportCountRow("Sections", value: presentation.sectionCount)
                        exportCountRow("History and queue records", value: presentation.jobCount)
                        exportCountRow("Thumbnail references", value: presentation.thumbnailReferenceCount)
                        exportCountRow("Diagnostic lines", value: presentation.diagnosticLineCount)
                    }
                    .padding(8)
                } else if isPreparing {
                    ProgressView("Preparing local preview...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    Text("The export preview is unavailable.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }

            Text("The package excludes downloaded media, browser cookies, security-scoped bookmarks, output paths, and raw diagnostic files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let feedback {
                feedbackView(feedback)
            }

            Spacer()

            HStack {
                if let exportedPackageURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedPackageURL])
                    } label: {
                        Label("Reveal Export in Finder", systemImage: "folder")
                    }
                    .accessibilityLabel("Reveal the completed local export package in Finder")
                }

                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    exportLocally()
                } label: {
                    Label("Choose Folder and Export...", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == nil || isPreparing)
                .accessibilityLabel("Choose a local folder and create the reviewed export package")
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 500)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        .task { await prepareDraft() }
    }

    private func sheetHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer()
            Image(systemName: "externaldrive")
                .font(.title2)
                .accessibilityHidden(true)
        }
    }

    private func exportCountRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(title): \(value)")
        }
    }

    private func feedbackView(_ feedback: LocalDataFeedback) -> some View {
        Label(feedback.message, systemImage: feedback.systemImage)
            .foregroundStyle(feedback.isError ? .red : .green)
            .textSelection(.enabled)
            .accessibilityLabel(feedback.message)
    }

    @MainActor
    private func prepareDraft() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            draft = try await store.makeLocalExportDraft(
                appVersion: appVersion,
                releaseChannel: releaseChannel
            )
            feedback = nil
        } catch {
            draft = nil
            feedback = .error("The local export preview could not be prepared.")
        }
    }

    @MainActor
    private func exportLocally() {
        guard let draft,
              let directory = OutputFolderPicker.choose(prompt: "Export") else { return }
        do {
            let packageURL = try writer.write(draft, to: directory)
            exportedPackageURL = packageURL
            feedback = .success("Exported locally: \(packageURL.path)")
        } catch {
            exportedPackageURL = nil
            feedback = .error("The export package could not be saved. Choose another local folder and try again.")
        }
    }
}

struct LocalDataManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DownloadStore

    @State private var pendingAction: PendingLocalDataAction?
    @State private var feedback: LocalDataFeedback?
    @State private var isPerformingAction = false

    private let mediaFileDeleter = SelectedMediaFileDeleter()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Manage Local Data")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text("Each action is separate and requires confirmation. Clearing history never deletes downloaded media files.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("History") {
                        VStack(spacing: 0) {
                            actionRow(for: completedHistoryDraft)
                            Divider()
                            actionRow(for: failedHistoryDraft)
                        }
                        .padding(6)
                    }

                    GroupBox("App Data") {
                        VStack(spacing: 0) {
                            actionRow(for: .actionPreview(.clearDiagnostics))
                            Divider()
                            actionRow(for: .actionPreview(.resetSettings))
                        }
                        .padding(6)
                    }

                    GroupBox("Downloaded Media") {
                        let presentation = LocalDeletionActionPresentation(
                            draft: .actionPreview(.deleteSelectedMediaFile)
                        )
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: presentation.symbolName)
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(presentation.title)
                                    .font(.body.weight(.medium))
                                Text("Select one regular file to review its filename before permanent deletion.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(presentation.retainedDataDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button("Choose File...") {
                                chooseMediaFile()
                            }
                            .disabled(isPerformingAction)
                            .accessibilityLabel("Choose one downloaded media file to review for permanent deletion")
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                    }
                }
            }

            if let feedback {
                Label(feedback.message, systemImage: feedback.systemImage)
                    .foregroundStyle(feedback.isError ? .red : .green)
                    .textSelection(.enabled)
                    .accessibilityLabel(feedback.message)
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 620, idealHeight: 700)
        .background(DownloadCenterAppearance.palette.windowBackground.color)
        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
        .preferredColorScheme(DownloadCenterAppearance.preferredScheme)
        .alert(item: $pendingAction) { pending in
            let presentation = pending.presentation
            return Alert(
                title: Text(presentation.title),
                message: Text("\(presentation.confirmationMessage)\n\n\(presentation.retainedDataDescription)"),
                primaryButton: .destructive(Text(presentation.confirmationButtonTitle)) {
                    perform(pending)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var completedHistoryDraft: LocalDeletionDraft {
        .historyPreview(action: .clearCompletedHistory, jobs: store.jobs)
    }

    private var failedHistoryDraft: LocalDeletionDraft {
        .historyPreview(action: .clearFailedAndCancelledHistory, jobs: store.jobs)
    }

    private func actionRow(for draft: LocalDeletionDraft) -> some View {
        let presentation = LocalDeletionActionPresentation(draft: draft)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.symbolName)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.body.weight(.medium))
                Text(presentation.confirmationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(presentation.retainedDataDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Review...") {
                pendingAction = PendingLocalDataAction(draft: draft)
            }
            .disabled(!presentation.isEnabled || isPerformingAction)
            .accessibilityLabel("Review \(presentation.title)")
        }
        .padding(.vertical, 10)
    }

    @MainActor
    private func chooseMediaFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review File"
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        pendingAction = PendingLocalDataAction(
            draft: .actionPreview(.deleteSelectedMediaFile, selectedMediaFileURL: selectedURL),
            selectedMediaURL: selectedURL
        )
    }

    private func perform(_ pending: PendingLocalDataAction) {
        isPerformingAction = true
        feedback = nil

        Task { @MainActor in
            do {
                switch pending.draft.action {
                case .clearCompletedHistory:
                    try await store.clearCompletedHistory()
                case .clearFailedAndCancelledHistory:
                    try await store.clearFailedAndCancelledHistory()
                case .clearDiagnostics:
                    try await store.clearDiagnostics()
                case .resetSettings:
                    try store.resetSettings()
                case .deleteSelectedMediaFile:
                    guard let selectedMediaURL = pending.selectedMediaURL else {
                        throw LocalSupportDataServiceError.mediaFileUnavailable
                    }
                    try mediaFileDeleter.delete(selectedMediaURL)
                }
                feedback = .success("\(pending.presentation.title) completed.")
            } catch {
                feedback = .error("\(pending.presentation.title) could not be completed. Some items may remain; review the list and try again.")
            }
            isPerformingAction = false
        }
    }
}

private struct PendingLocalDataAction: Identifiable {
    let draft: LocalDeletionDraft
    let selectedMediaURL: URL?

    init(draft: LocalDeletionDraft, selectedMediaURL: URL? = nil) {
        self.draft = draft
        self.selectedMediaURL = selectedMediaURL
    }

    var id: String { draft.action.rawValue }
    var presentation: LocalDeletionActionPresentation {
        LocalDeletionActionPresentation(draft: draft)
    }
}

private struct LocalDataFeedback: Equatable {
    var message: String
    var systemImage: String
    var isError: Bool

    static func success(_ message: String) -> LocalDataFeedback {
        LocalDataFeedback(message: message, systemImage: "checkmark.circle.fill", isError: false)
    }

    static func error(_ message: String) -> LocalDataFeedback {
        LocalDataFeedback(message: message, systemImage: "exclamationmark.triangle.fill", isError: true)
    }
}
