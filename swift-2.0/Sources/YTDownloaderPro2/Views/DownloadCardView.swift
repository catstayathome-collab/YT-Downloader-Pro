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

struct DownloadCardPresentation: Equatable {
    let job: DownloadJob

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
}

struct DownloadCardView: View {
    @EnvironmentObject private var store: DownloadStore

    let job: DownloadJob
    var onEdit: (DownloadJob) -> Void = { _ in }

    @State private var showsCancelConfirmation = false
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(presentation.statusLabel)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .fixedSize()
                }

                Text(presentation.formatSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showsProgress {
                    ProgressView(value: max(0, min(job.progress, 1)))
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Download progress")
                        .accessibilityValue(progressAccessibilityValue)
                }

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let outputURL = job.outputURL {
                    Text(outputURL.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .alert("Cancel this download?", isPresented: $showsCancelConfirmation) {
            Button("Cancel Download", role: .destructive) {
                Task { await store.cancel(job.id) }
            }
            Button("Keep Download", role: .cancel) {}
        } message: {
            Text("The current partial download will be removed.")
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
        .frame(width: 144, height: 81)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .disabled(actionNeedsOutputURL(action) && job.outputURL == nil)
        .help(action.accessibilityLabel)
        .accessibilityLabel(action.accessibilityLabel)
    }

    // Views route intent through the Store; only desktop file opening stays local to the presentation layer.
    private func route(_ action: DownloadCardAction) {
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
        case .cancelWithConfirmation:
            showsCancelConfirmation = true
        case .play:
            if let outputURL = job.outputURL {
                NSWorkspace.shared.open(outputURL)
            }
        case .revealInFinder:
            if let outputURL = job.outputURL {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            }
        case .retry:
            Task { await store.retry(job.id) }
        case .errorDetails:
            showsErrorDetails = true
        case .reAdd:
            Task { await store.reAdd(job.id) }
        case .removeRecord:
            Task { await store.removeRecord(job.id) }
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
        case .completed: .green
        case .failed: .red
        case .paused, .cancelled: .orange
        case .queued, .analyzing, .downloading, .merging: .secondary
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

    private func actionNeedsOutputURL(_ action: DownloadCardAction) -> Bool {
        action == .play || action == .revealInFinder
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
