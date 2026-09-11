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
    var titleSource: MediaTitleSource?
    var duration: TimeInterval?
    var thumbnailCachePath: String?
    var sourceMetadata: String?
    var status: DownloadStatus
    var awaitsBatchAnalysis: Bool
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
        titleSource: MediaTitleSource? = nil,
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
        awaitsBatchAnalysis: Bool = false,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        updatedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.playlistID = playlistID
        self.title = title
        self.titleSource = titleSource
        self.duration = duration
        self.thumbnailCachePath = thumbnailCachePath
        self.sourceMetadata = sourceMetadata
        self.status = status
        self.awaitsBatchAnalysis = awaitsBatchAnalysis
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

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case playlistID
        case title
        case titleSource
        case duration
        case thumbnailCachePath
        case sourceMetadata
        case status
        case awaitsBatchAnalysis
        case progress
        case downloadedBytes
        case totalBytes
        case speedBytesPerSecond
        case estimatedTimeRemaining
        case reservedOutputBasename
        case outputURL
        case options
        case failure
        case retryCount
        case createdAt
        case startedAt
        case updatedAt
        case completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        playlistID = try container.decodeIfPresent(String.self, forKey: .playlistID)
        title = try container.decode(String.self, forKey: .title)
        titleSource = try container.decodeIfPresent(MediaTitleSource.self, forKey: .titleSource)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        thumbnailCachePath = try container.decodeIfPresent(String.self, forKey: .thumbnailCachePath)
        sourceMetadata = try container.decodeIfPresent(String.self, forKey: .sourceMetadata)
        status = try container.decode(DownloadStatus.self, forKey: .status)
        awaitsBatchAnalysis = try container.decodeIfPresent(Bool.self, forKey: .awaitsBatchAnalysis) ?? false
        progress = try container.decode(Double.self, forKey: .progress)
        downloadedBytes = try container.decodeIfPresent(Int64.self, forKey: .downloadedBytes)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        speedBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .speedBytesPerSecond)
        estimatedTimeRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .estimatedTimeRemaining)
        reservedOutputBasename = try container.decodeIfPresent(String.self, forKey: .reservedOutputBasename)
        outputURL = try container.decodeIfPresent(URL.self, forKey: .outputURL)
        options = try container.decode(DownloadOptions.self, forKey: .options)
        failure = try container.decodeIfPresent(DownloadFailure.self, forKey: .failure)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(playlistID, forKey: .playlistID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(titleSource, forKey: .titleSource)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(thumbnailCachePath, forKey: .thumbnailCachePath)
        try container.encodeIfPresent(sourceMetadata, forKey: .sourceMetadata)
        try container.encode(status, forKey: .status)
        try container.encode(awaitsBatchAnalysis, forKey: .awaitsBatchAnalysis)
        try container.encode(progress, forKey: .progress)
        try container.encodeIfPresent(downloadedBytes, forKey: .downloadedBytes)
        try container.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(speedBytesPerSecond, forKey: .speedBytesPerSecond)
        try container.encodeIfPresent(estimatedTimeRemaining, forKey: .estimatedTimeRemaining)
        try container.encodeIfPresent(reservedOutputBasename, forKey: .reservedOutputBasename)
        try container.encodeIfPresent(outputURL, forKey: .outputURL)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
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

    func scrubbingRetainedMediaURLCredentials() -> DownloadJob {
        var scrubbed = self
        scrubbed.sourceURL = MediaURLValidator.credentialFreeEquivalent(of: scrubbed.sourceURL)
            ?? scrubbed.sourceURL
        if let sourceMetadata = scrubbed.sourceMetadata {
            scrubbed.sourceMetadata = MediaURLValidator.credentialFreeEquivalent(of: sourceMetadata)
                ?? sourceMetadata
        }
        return scrubbed
    }
}
