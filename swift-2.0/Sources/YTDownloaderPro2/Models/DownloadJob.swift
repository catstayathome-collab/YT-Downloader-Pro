import Foundation

enum DownloadTransitionError: Error, Equatable, Sendable {
    case mergingCannotPause
    case terminalStateCannotBecomeActive
    case queuedJobCannotCompleteDirectly
}

struct DownloadJob: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var sourceURL: String
    var playlistID: String?
    var title: String
    var duration: TimeInterval?
    var thumbnailCachePath: String?
    var sourceMetadata: String?
    var status: DownloadStatus
    var progress: Double
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var speedBytesPerSecond: Double?
    var estimatedTimeRemaining: TimeInterval?
    var reservedOutputBasename: String?
    var outputURL: URL?
    var options: DownloadOptions
    var failure: DownloadFailure?
    var retryCount: Int
    var createdAt: Date
    var startedAt: Date?
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        sourceURL: String,
        playlistID: String? = nil,
        title: String,
        duration: TimeInterval? = nil,
        thumbnailCachePath: String? = nil,
        sourceMetadata: String? = nil,
        status: DownloadStatus = .queued,
        progress: Double = 0,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        speedBytesPerSecond: Double? = nil,
        estimatedTimeRemaining: TimeInterval? = nil,
        reservedOutputBasename: String? = nil,
        outputURL: URL? = nil,
        options: DownloadOptions = .defaults,
        failure: DownloadFailure? = nil,
        retryCount: Int = 0,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        updatedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.playlistID = playlistID
        self.title = title
        self.duration = duration
        self.thumbnailCachePath = thumbnailCachePath
        self.sourceMetadata = sourceMetadata
        self.status = status
        self.progress = progress
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.reservedOutputBasename = reservedOutputBasename
        self.outputURL = outputURL
        self.options = options
        self.failure = failure
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    mutating func transition(to newStatus: DownloadStatus, at timestamp: Date = .now) throws {
        if status == .merging, newStatus == .paused {
            throw DownloadTransitionError.mergingCannotPause
        }
        if status.isTerminal, newStatus.isActive {
            throw DownloadTransitionError.terminalStateCannotBecomeActive
        }
        if status == .queued, newStatus == .completed {
            throw DownloadTransitionError.queuedJobCannotCompleteDirectly
        }

        status = newStatus
        updatedAt = timestamp

        if newStatus.isActive, startedAt == nil {
            startedAt = timestamp
        }
        if newStatus == .completed {
            completedAt = timestamp
        }
    }
}
