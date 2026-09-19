import AppKit
import SwiftUI

struct LocalDataExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
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
            sheetHeader(title: L10n.string(.dataExportTitle, locale: locale))

            Text(L10n.string(.dataExportNotice, locale: locale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(L10n.string(.dataExportPreviewTitle, locale: locale)) {
                if let draft {
                    let presentation = LocalExportPreviewPresentation(draft: draft)
                    VStack(spacing: 10) {
                        exportCountRow(L10n.string(.dataExportSections, locale: locale), value: presentation.sectionCount)
                        exportCountRow(L10n.string(.dataExportJobRecords, locale: locale), value: presentation.jobCount)
                        exportCountRow(L10n.string(.dataExportThumbnailReferences, locale: locale), value: presentation.thumbnailReferenceCount)
                        exportCountRow(L10n.string(.dataExportDiagnosticLines, locale: locale), value: presentation.diagnosticLineCount)
                    }
                    .padding(8)
                } else if isPreparing {
                    ProgressView(L10n.string(.dataExportPreparing, locale: locale))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    Text(L10n.string(.dataExportUnavailable, locale: locale))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }

            Text(L10n.string(.dataExportExclusions, locale: locale))
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
                        Label(L10n.string(.dataExportReveal, locale: locale), systemImage: "folder")
                    }
                    .accessibilityLabel(L10n.string(.dataExportReveal, locale: locale))
                }

                Spacer()
                Button(L10n.string(.commonClose, locale: locale)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    exportLocally()
                } label: {
                    Label(L10n.string(.dataExportChooseAndExport, locale: locale), systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == nil || isPreparing)
                .accessibilityLabel(L10n.string(.dataExportChooseAndExport, locale: locale))
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
            feedback = .error(L10n.string(.dataExportPreviewFailed, locale: locale))
        }
    }

    @MainActor
    private func exportLocally() {
        guard let draft,
              let directory = OutputFolderPicker.choose(
                prompt: L10n.string(.dataExportChooseAndExport, locale: locale)
              ) else { return }
        do {
            let packageURL = try writer.write(draft, to: directory)
            exportedPackageURL = packageURL
            feedback = .success(L10n.string(.dataExportSaved, locale: locale, packageURL.path))
        } catch {
            exportedPackageURL = nil
            feedback = .error(L10n.string(.dataExportSaveFailed, locale: locale))
        }
    }
}

struct LocalDataManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: DownloadStore

    @State private var pendingAction: PendingLocalDataAction?
    @State private var feedback: LocalDataFeedback?
    @State private var isPerformingAction = false

    private let mediaFileDeleter = SelectedMediaFileDeleter()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.string(.dataManagementTitle, locale: locale))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.string(.commonClose, locale: locale)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(L10n.string(.dataManagementNotice, locale: locale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox(L10n.string(.dataManagementHistory, locale: locale)) {
                        VStack(spacing: 0) {
                            actionRow(for: completedHistoryDraft)
                            Divider()
                            actionRow(for: failedHistoryDraft)
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.string(.dataManagementAppData, locale: locale)) {
                        VStack(spacing: 0) {
                            actionRow(for: .actionPreview(.clearDiagnostics))
                            Divider()
                            actionRow(for: .actionPreview(.resetSettings))
                        }
                        .padding(6)
                    }

                    GroupBox(L10n.string(.dataManagementDownloadedMedia, locale: locale)) {
                        let presentation = LocalDeletionActionPresentation(
                            draft: .actionPreview(.deleteSelectedMediaFile),
                            locale: locale
                        )
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: presentation.symbolName)
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(presentation.title)
                                    .font(.body.weight(.medium))
                                Text(L10n.string(.dataManagementSelectFileDescription, locale: locale))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(presentation.retainedDataDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button(L10n.string(.dataManagementChooseFile, locale: locale)) {
                                chooseMediaFile()
                            }
                            .disabled(isPerformingAction)
                            .accessibilityLabel(L10n.string(.dataManagementChooseFile, locale: locale))
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
            let presentation = LocalDeletionActionPresentation(draft: pending.draft, locale: locale)
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
        let presentation = LocalDeletionActionPresentation(draft: draft, locale: locale)
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

            Button(L10n.string(.commonReview, locale: locale)) {
                pendingAction = PendingLocalDataAction(draft: draft)
            }
            .disabled(!presentation.isEnabled || isPerformingAction)
            .accessibilityLabel("\(L10n.string(.commonReview, locale: locale)): \(presentation.title)")
        }
        .padding(.vertical, 10)
    }

    @MainActor
    private func chooseMediaFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string(.dataManagementReviewFilePrompt, locale: locale)
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
                let title = LocalDeletionActionPresentation(draft: pending.draft, locale: locale).title
                feedback = .success(L10n.string(.dataManagementActionCompleted, locale: locale, title))
            } catch {
                let title = LocalDeletionActionPresentation(draft: pending.draft, locale: locale).title
                feedback = .error(L10n.string(.dataManagementActionFailed, locale: locale, title))
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
