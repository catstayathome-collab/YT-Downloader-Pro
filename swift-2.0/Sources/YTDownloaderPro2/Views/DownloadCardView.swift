import AppKit
import SwiftUI

enum DownloadCardAction: Equatable, Hashable {
    case edit
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
        case .edit: "slider.horizontal.3"
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

    var accessibilityLabel: String {
        switch self {
        case .edit: "Edit download options"
        case .startNow: "Start now"
        case .pause: "Pause download"
        case .resume: "Resume download"
        case .cancel, .cancelWithConfirmation: "Cancel download"
        case .play: "Play downloaded media"
        case .revealInFinder: "Reveal in Finder"
        case .retry: "Retry download"
        case .errorDetails: "Show error details"
        case .reAdd: "Add download again"
        case .removeRecord: "Remove record"
        }
    }
}

enum DownloadConfirmation: String, Identifiable, Equatable {
    case cancelMerging
    case cancelActiveAndWaiting
    case removeRecord
    case clearCompleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cancelMerging: "Cancel this download?"
        case .cancelActiveAndWaiting: "Cancel active and waiting downloads?"
        case .removeRecord: "Remove this record?"
        case .clearCompleted: "Clear completed records?"
        }
    }

    var destructiveButtonTitle: String {
        switch self {
        case .cancelMerging: "Cancel Download"
        case .cancelActiveAndWaiting: "Cancel Downloads"
        case .removeRecord: "Remove Record"
        case .clearCompleted: "Clear Completed"
        }
    }

    var message: String {
        switch self {
        case .cancelMerging:
            "Cancelling now removes partial download files created by this job."
        case .cancelActiveAndWaiting:
            "Partial files for active and waiting downloads will be removed."
        case .removeRecord:
            "The media file will remain. Only this history record and its cached thumbnail will be removed."
        case .clearCompleted:
            "Downloaded media files will remain. Only completed history records and their cached thumbnails will be removed."
        }
    }
}

struct DownloadCardLayout: Equatable {
    let cardHeight: Double
    let thumbnailHeight: Double
    let titleLineCount: Int
    let reservesProgressRow: Bool
    let reservesDetailRow: Bool
    let reservesOutputPathRow: Bool

    static let approved = DownloadCardLayout(
        cardHeight: 140,
        thumbnailHeight: 81,
        titleLineCount: 2,
        reservesProgressRow: true,
        reservesDetailRow: true,
        reservesOutputPathRow: true
    )
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
            [.retry, .errorDetails, .removeRecord]
        case .cancelled:
            [.reAdd, .removeRecord]
        }
    }

    var statusLabel: String {
        switch job.status {
        case .queued: "Queued"
        case .analyzing: "Analyzing"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .merging: "Finishing"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var formatSummary: String {
        job.options.outputKind == .mp3 ? "MP3 audio" : "MP4 video"
    }

    var layout: DownloadCardLayout { .approved }

    func confirmation(for action: DownloadCardAction) -> DownloadConfirmation? {
        switch action {
        case .cancelWithConfirmation:
            .cancelMerging
        case .removeRecord:
            .removeRecord
        case .edit, .startNow, .pause, .resume, .cancel, .play, .revealInFinder, .retry, .errorDetails, .reAdd:
            nil
        }
    }

    func isEnabled(_ action: DownloadCardAction) -> Bool {
        switch action {
        case .play, .revealInFinder:
            validatedOutputFileURL != nil
        case .edit, .startNow, .pause, .resume, .cancel, .cancelWithConfirmation, .retry, .errorDetails, .reAdd, .removeRecord:
            true
        }
    }

    func help(for action: DownloadCardAction) -> String {
        guard !isEnabled(action) else { return action.accessibilityLabel }
        return switch action {
        case .play:
            "Play unavailable: file is missing or is not a regular file"
        case .revealInFinder:
            "Reveal unavailable: file is missing or is not a regular file"
        case .edit, .startNow, .pause, .resume, .cancel, .cancelWithConfirmation, .retry, .errorDetails, .reAdd, .removeRecord:
            action.accessibilityLabel
        }
    }

    func accessibilityLabel(for action: DownloadCardAction) -> String {
        guard !isEnabled(action) else { return action.accessibilityLabel }
        return "\(action.accessibilityLabel), unavailable because the file is missing or is not a regular file"
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

    let job: DownloadJob
    var onEdit: (DownloadJob) -> Void = { _ in }

    @State private var pendingConfirmation: DownloadConfirmation?
    @State private var showsErrorDetails = false

    private let presentation: DownloadCardPresentation

    init(job: DownloadJob, onEdit: @escaping (DownloadJob) -> Void = { _ in }) {
        self.job = job
        self.onEdit = onEdit
        presentation = DownloadCardPresentation(job: job)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.title)
                        .font(.headline)
                        .foregroundStyle(DownloadCenterAppearance.palette.primaryText.color)
                        .lineLimit(presentation.layout.titleLineCount)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(presentation.statusLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .fixedSize()
                }
                .frame(height: 34, alignment: .top)

                Text(presentation.formatSummary)
                    .font(.subheadline)
                    .foregroundStyle(DownloadCenterAppearance.palette.secondaryText.color)
                    .lineLimit(1)
                    .frame(height: 17, alignment: .topLeading)

                Group {
                    if showsProgress {
                        ProgressView(value: max(0, min(job.progress, 1)))
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Download progress")
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
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(presentation.actions, id: \.self) { action in
                    cardActionButton(action)
                }
            }
            .frame(minWidth: 30, alignment: .trailing)
        }
        .frame(height: presentation.layout.cardHeight - 24, alignment: .top)
        .padding(12)
        .background(DownloadCenterAppearance.palette.cardBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DownloadCenterAppearance.palette.border.color, lineWidth: 1)
        }
        .alert(item: $pendingConfirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.destructiveButtonTitle)) {
                    performConfirmed(confirmation)
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showsErrorDetails) {
            if let failure = job.failure {
                ErrorDetailsView(failure: failure)
            }
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
        .help(presentation.help(for: action))
        .accessibilityLabel(presentation.accessibilityLabel(for: action))
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
        case .edit:
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
        let transfer = byteDescription(job.downloadedBytes) + " of " + byteDescription(job.totalBytes)
        guard job.status == .downloading else { return transfer }
        let speed = job.speedBytesPerSecond.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" }
        let eta = job.estimatedTimeRemaining.map { "ETA " + durationDescription($0) }
        return [transfer, speed, eta].compactMap { $0 }.joined(separator: "  |  ")
    }

    private var progressAccessibilityValue: String {
        NumberFormatter.localizedString(from: NSNumber(value: max(0, min(job.progress, 1))), number: .percent)
    }

    private func byteDescription(_ value: Int64?) -> String {
        guard let value else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func durationDescription(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "Unknown"
    }
}
