import Foundation

enum DownloadPhase: String, Codable, Equatable, Sendable {
    case downloading
    case merging
    case postprocessing
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
    case phase(DownloadPhase)
    case progress(JobProgress)
    case output(URL)
    case diagnostic(String)
    case completed
}
