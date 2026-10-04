import Foundation

enum DownloadPhase: String, Codable, Equatable, Sendable {
    case analyzing
    case downloading
    case merging
    case postprocessing
}

enum MediaProcessingStage: String, Codable, Equatable, Sendable {
    case verifying
    case converting
    case remuxing
}

struct JobProgress: Codable, Equatable, Sendable {
    let fraction: Double?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let etaSeconds: TimeInterval?

    init(
        fraction: Double?,
        downloadedBytes: Int64?,
        totalBytes: Int64?,
        bytesPerSecond: Double?,
        etaSeconds: TimeInterval?
    ) {
        self.fraction = fraction
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds
    }
}

enum DownloadEvent: Codable, Equatable, Sendable {
    case reservedBasename(String)
    case phase(DownloadPhase)
    case processingStage(MediaProcessingStage)
    case progress(JobProgress)
    case output(URL)
    case diagnostic(String)
    case completed
}
