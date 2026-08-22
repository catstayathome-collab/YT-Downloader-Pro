import AppKit
import SwiftUI

enum DownloadCardAction: Equatable, Hashable {
    case edit
    case editAndRetry
    case startNow
    case pause
    case resume
    case cancel
    case cancelWithConfirmation
    case play
    case revealInFinder
    case retry
    case errorDetails
    case reAdd
    case removeRecord

    var symbolName: String {
        switch self {
        case .edit, .editAndRetry: "slider.horizontal.3"
        case .startNow: "play.fill"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .cancel, .cancelWithConfirmation: "xmark"
        case .play: "play.circle"
        case .revealInFinder: "folder"
        case .retry: "arrow.clockwise"
        case .errorDetails: "exclamationmark.circle"
        case .reAdd: "plus"
        case .removeRecord: "trash"
        }
    }

    var accessibilityLabel: String { accessibilityLabel(locale: Locale(identifier: "en")) }

    func accessibilityLabel(locale: Locale) -> String {
        switch self {
        case .edit: L10n.string(.downloadActionEdit, locale: locale)
        case .editAndRetry: L10n.string(.downloadActionEditAndRetry, locale: locale)
        case .startNow: L10n.string(.downloadActionStartNow, locale: locale)
        case .pause: L10n.string(.downloadActionPause, locale: locale)
        case .resume: L10n.string(.downloadActionResume, locale: locale)
        case .cancel, .cancelWithConfirmation: L10n.string(.downloadActionCancel, locale: locale)
        case .play: L10n.string(.downloadActionPlay, locale: locale)
        case .revealInFinder: L10n.string(.downloadActionReveal, locale: locale)
        case .retry: L10n.string(.downloadActionRetry, locale: locale)
        case .errorDetails: L10n.string(.downloadActionErrorDetails, locale: locale)
        case .reAdd: L10n.string(.downloadActionReAdd, locale: locale)
        case .removeRecord: L10n.string(.downloadActionRemoveRecord, locale: locale)
        }
    }
}

enum DownloadConfirmation: String, Identifiable, Equatable {
    case cancelMerging
    case cancelActiveAndWaiting
    case removeRecord
    case clearCompleted

    var id: String { rawValue }

    var title: String { title(locale: Locale(identifier: "en")) }

    func title(locale: Locale) -> String {
        switch self {
        case .cancelMerging: L10n.string(.confirmationCancelMergingTitle, locale: locale)
        case .cancelActiveAndWaiting: L10n.string(.confirmationCancelActiveTitle, locale: locale)
        case .removeRecord: L10n.string(.confirmationRemoveRecordTitle, locale: locale)
        case .clearCompleted: L10n.string(.confirmationClearCompletedTitle, locale: locale)
        }
    }

    var destructiveButtonTitle: String { destructiveButtonTitle(locale: Locale(identifier: "en")) }

    func destructiveButtonTitle(locale: Locale) -> String {
        switch self {
        case .cancelMerging: L10n.string(.confirmationCancelDownloadButton, locale: locale)
        case .cancelActiveAndWaiting: L10n.string(.confirmationCancelDownloadsButton, locale: locale)
        case .removeRecord: L10n.string(.confirmationRemoveRecordButton, locale: locale)
        case .clearCompleted: L10n.string(.confirmationClearCompletedButton, locale: locale)
        }
    }

    var message: String { message(locale: Locale(identifier: "en")) }

    func message(locale: Locale) -> String {
        switch self {
        case .cancelMerging: L10n.string(.confirmationCancelMergingMessage, locale: locale)
        case .cancelActiveAndWaiting: L10n.string(.confirmationCancelActiveMessage, locale: locale)
        case .removeRecord: L10n.string(.confirmationRemoveRecordMessage, locale: locale)
        case .clearCompleted: L10n.string(.confirmationClearCompletedMessage, locale: locale)
        }
    }
}

struct DownloadCardLayout: Equatable {
    let minimumWidth: Double
    let cardHeight: Double
    let thumbnailHeight: Double
    let titleLineCount: Int
    let reservesProgressRow: Bool
    let reservesDetailRow: Bool
    let reservesOutputPathRow: Bool
    let failureSummaryLineCount: Int
    let failureRecoveryLineCount: Int

    static let approved = DownloadCardLayout(
        minimumWidth: 500,
        cardHeight: 140,
        thumbnailHeight: 81,
        titleLineCount: 2,
        reservesProgressRow: true,
        reservesDetailRow: true,
        reservesOutputPathRow: true,
        failureSummaryLineCount: 1,
        failureRecoveryLineCount: 2
    )
}

struct DownloadCardFailureText: Equatable {
    let summary: String
    let recovery: String
}

struct DownloadCardPresentation: Equatable {
    let job: DownloadJob
    let validatedOutputFileURL: URL?

    init(job: DownloadJob, fileManager: FileManager = .default) {
        self.job = job
        validatedOutputFileURL = Self.existingRegularFileURL(job.outputURL, fileManager: fileManager)
    }

    // This keeps each lifecycle state tied to its approved, testable command set.
    var actions: [DownloadCardAction] {
        switch job.status {
        case .queued:
            [.edit, .startNow, .cancel]
        case .analyzing, .downloading:
            [.pause, .cancel]
        case .paused:
            [.resume, .cancel]
        case .merging:
            [.cancelWithConfirmation]
        case .completed:
            [.play, .revealInFinder, .removeRecord]
        case .failed:
            job.failure?.category.supportsOptionsRecovery == true
                ? [.editAndRetry, .errorDetails, .removeRecord]
                : [.retry, .errorDetails, .removeRecord]
        case .cancelled:
            [.reAdd, .removeRecord]
        }
    }

    var statusLabel: String { statusLabel(locale: Locale(identifier: "en")) }

    func statusLabel(locale: Locale) -> String {
        switch job.status {
        case .queued: L10n.string(.downloadStatusQueued, locale: locale)
        case .analyzing: L10n.string(.downloadStatusAnalyzing, locale: locale)
        case .downloading: L10n.string(.downloadStatusDownloading, locale: locale)
        case .paused: L10n.string(.downloadStatusPaused, locale: locale)
        case .merging: L10n.string(.downloadStatusFinishing, locale: locale)
        case .completed: L10n.string(.downloadStatusCompleted, locale: locale)
        case .failed: L10n.string(.downloadStatusFailed, locale: locale)
        case .cancelled: L10n.string(.downloadStatusCancelled, locale: locale)
        }
    }

    var formatSummary: String { formatSummary(locale: Locale(identifier: "en")) }

    func formatSummary(locale: Locale) -> String {
        L10n.string(job.options.outputKind == .mp3 ? .downloadCardFormatMP3 : .downloadCardFormatMP4, locale: locale)
    }

    var layout: DownloadCardLayout { .approved }

    func failureText(locale: Locale) -> DownloadCardFailureText? {
        guard job.status == .failed else { return nil }
        let failure = job.failure ?? DownloadFailure(category: .downloadFailed)
        return DownloadCardFailureText(
            summary: failure.userSummary(locale: locale.identifier),
            recovery: failure.userRecoverySuggestion(locale: locale.identifier)
        )
    }

    func confirmation(for action: DownloadCardAction) -> DownloadConfirmation? {
        switch action {
        case .cancelWithConfirmation:
            .cancelMerging
        case .removeRecord:
            .removeRecord
        case .edit, .editAndRetry, .startNow, .pause, .resume, .cancel, .play, .revealInFinder, .retry, .errorDetails, .reAdd:
            nil
        }
    }

    func isEnabled(_ action: DownloadCardAction) -> Bool {
        switch action {
        case .play, .revealInFinder:
            validatedOutputFileURL != nil
        case .edit, .editAndRetry, .startNow, .pause, .resume, .cancel, .cancelWithConfirmation, .retry, .errorDetails, .reAdd, .removeRecord:
            true
        }
    }

    func help(for action: DownloadCardAction) -> String {
        help(for: action, locale: Locale(identifier: "en"))
    }

    func help(for action: DownloadCardAction, locale: Locale) -> String {
        guard !isEnabled(action) else { return action.accessibilityLabel(locale: locale) }
        return switch action {
        case .play: L10n.string(.downloadActionPlayUnavailable, locale: locale)
        case .revealInFinder: L10n.string(.downloadActionRevealUnavailable, locale: locale)
        case .edit, .editAndRetry, .startNow, .pause, .resume, .cancel, .cancelWithConfirmation, .retry, .errorDetails, .reAdd, .removeRecord:
            action.accessibilityLabel(locale: locale)
        }
    }

    func accessibilityLabel(for action: DownloadCardAction) -> String {
        accessibilityLabel(for: action, locale: Locale(identifier: "en"))
    }

    func accessibilityLabel(for action: DownloadCardAction, locale: Locale) -> String {
        let label = action.accessibilityLabel(locale: locale)
        guard !isEnabled(action) else { return label }
        return L10n.string(.downloadActionFileUnavailable, locale: locale, label)
    }

    private static func existingRegularFileURL(_ url: URL?, fileManager: FileManager) -> URL? {
        guard let url, url.isFileURL else { return nil }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return resolvedURL
    }
}

struct DownloadCardView: View {
    @EnvironmentObject private var store: DownloadStore
    @Environment(\.locale) private var locale

    let job: DownloadJob
    var isSelected = false
    var onEdit: (DownloadJob) -> Void = { _ in }

    @State private var pendingConfirmation: DownloadConfirmation?
    @State private var showsErrorDetails = false

    private let presentation: DownloadCardPresentation

    init(job: DownloadJob, isSelected: Bool = false, onEdit: @escaping (DownloadJob) -> Void = { _ in }) {
        self.job = job
        self.isSelected = isSelected
        self.onEdit = onEdit
        presentation = DownloadCardPresentation(job: job)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MediaFallbackText.localized(job.title, source: job.titleSource, locale: locale))
                        .font(.headline)
                        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
                        .lineLimit(presentation.layout.titleLineCount)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(presentation.statusLabel(locale: locale))
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .fixedSize()
                }
                .frame(height: 34, alignment: .top)

                Text(presentation.formatSummary(locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                    .lineLimit(1)
                    .frame(height: 17, alignment: .topLeading)

                if let failureText = presentation.failureText(locale: locale) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(failureText.summary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.70, green: 0.12, blue: 0.12))
                            .lineLimit(presentation.layout.failureSummaryLineCount)
                            .truncationMode(.tail)
                            .frame(height: 14, alignment: .topLeading)
                        Text(failureText.recovery)
                            .font(.caption2)
                            .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                            .lineLimit(presentation.layout.failureRecoveryLineCount)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 34, alignment: .topLeading)
                    }
                    .frame(height: 51, alignment: .topLeading)
                } else {
                    lifecycleRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(presentation.actions, id: \.self) { action in
                    cardActionButton(action)
                }
            }
            .frame(minWidth: 30, alignment: .trailing)
        }
        .frame(minWidth: presentation.layout.minimumWidth, minHeight: presentation.layout.cardHeight - 24, maxHeight: presentation.layout.cardHeight - 24, alignment: .top)
        .padding(12)
        .background(DownloadCenterAppearance.palette.cardBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : DownloadCenterAppearance.palette.border.color, lineWidth: isSelected ? 2 : 1)
        }
        .alert(item: $pendingConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title(locale: locale)),
                message: Text(confirmation.message(locale: locale)),
                primaryButton: .destructive(Text(confirmation.destructiveButtonTitle(locale: locale))) {
                    performConfirmed(confirmation)
                },
                secondaryButton: .cancel(Text(L10n.string(.commonCancel, locale: locale)))
            )
        }
        .sheet(isPresented: $showsErrorDetails) {
            if let failure = job.failure {
                ErrorDetailsView(failure: failure)
            }
        }
    }

    private var lifecycleRows: some View {
        Group {
            Group {
                if showsProgress {
                    ProgressView(value: max(0, min(job.progress, 1)))
                        .progressViewStyle(.linear)
                        .accessibilityLabel(L10n.string(.downloadCardProgress, locale: locale))
                        .accessibilityValue(progressAccessibilityValue)
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 8)

            Text(detailLine)
                .font(.caption)
                .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 14, alignment: .leading)

            Text(job.outputURL?.path ?? " ")
                .font(.caption2)
                .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .opacity(job.outputURL == nil ? 0 : 1)
                .accessibilityHidden(job.outputURL == nil)
                .frame(height: 14, alignment: .leading)
        }
    }

    private var thumbnail: some View {
        Group {
            if let path = job.thumbnailCachePath,
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 144, height: presentation.layout.thumbnailHeight)
        .background(DownloadCenterAppearance.palette.thumbnailBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cardActionButton(_ action: DownloadCardAction) -> some View {
        Button {
            route(action)
        } label: {
            Image(systemName: action.symbolName)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(!presentation.isEnabled(action))
        .help(presentation.help(for: action, locale: locale))
        .accessibilityLabel(presentation.accessibilityLabel(for: action, locale: locale))
    }

    // Views route intent through the Store; only desktop file opening stays local to the presentation layer.
    private func route(_ action: DownloadCardAction) {
        let currentPresentation = DownloadCardPresentation(job: job)
        guard currentPresentation.isEnabled(action) else { return }
        if let confirmation = currentPresentation.confirmation(for: action) {
            pendingConfirmation = confirmation
            return
        }
        switch action {
        case .edit, .editAndRetry:
            onEdit(job)
        case .startNow:
            Task { await store.start(job.id) }
        case .pause:
            Task { await store.pause(job.id) }
        case .resume:
            Task { await store.resume(job.id) }
        case .cancel:
            Task { await store.cancel(job.id) }
        case .cancelWithConfirmation, .removeRecord:
            return
        case .play:
            if let outputURL = currentPresentation.validatedOutputFileURL {
                NSWorkspace.shared.open(outputURL)
            }
        case .revealInFinder:
            if let outputURL = currentPresentation.validatedOutputFileURL {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            }
        case .retry:
            Task { await store.retry(job.id) }
        case .errorDetails:
            showsErrorDetails = true
        case .reAdd:
            Task { await store.reAdd(job.id) }
        }
    }

    private func performConfirmed(_ confirmation: DownloadConfirmation) {
        switch confirmation {
        case .cancelMerging:
            Task { await store.cancel(job.id) }
        case .removeRecord:
            Task { await store.removeRecord(job.id) }
        case .cancelActiveAndWaiting, .clearCompleted:
            return
        }
    }

    private var showsProgress: Bool {
        switch job.status {
        case .analyzing, .downloading, .paused, .merging:
            true
        case .queued, .completed, .failed, .cancelled:
            false
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: Color(red: 0.08, green: 0.45, blue: 0.20)
        case .failed: Color(red: 0.70, green: 0.12, blue: 0.12)
        case .paused, .cancelled: Color(red: 0.66, green: 0.34, blue: 0.05)
        case .queued, .analyzing, .downloading, .merging: DownloadCenterAppearance.palette.secondaryText.color
        }
    }

    private var detailLine: String {
        let transfer = L10n.string(
            .downloadCardDetailTransfer,
            locale: locale,
            byteDescription(job.downloadedBytes),
            byteDescription(job.totalBytes)
        )
        guard job.status == .downloading else { return transfer }
        let speed = job.speedBytesPerSecond.map {
            L10n.string(.downloadCardDetailSpeed, locale: locale, byteDescription(Int64($0)))
        }
        let eta = job.estimatedTimeRemaining.map {
            L10n.string(.downloadCardDetailETA, locale: locale, durationDescription($0))
        }
        switch (speed, eta) {
        case let (.some(speed), .some(eta)):
            return L10n.string(.downloadCardDetailTransferSpeedETA, locale: locale, transfer, speed, eta)
        case let (.some(speed), .none):
            return L10n.string(.downloadCardDetailTransferSpeed, locale: locale, transfer, speed)
        case let (.none, .some(eta)):
            return L10n.string(.downloadCardDetailTransferETA, locale: locale, transfer, eta)
        case (.none, .none):
            return transfer
        }
    }

    private var progressAccessibilityValue: String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        return formatter.string(from: NSNumber(value: max(0, min(job.progress, 1)))) ?? ""
    }

    private func byteDescription(_ value: Int64?) -> String {
        guard let value else { return L10n.string(.downloadCardUnknownSize, locale: locale) }
        return value.formatted(.byteCount(style: .file).locale(locale))
    }

    private func durationDescription(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? L10n.string(.downloadCardUnknown, locale: locale)
    }
}
