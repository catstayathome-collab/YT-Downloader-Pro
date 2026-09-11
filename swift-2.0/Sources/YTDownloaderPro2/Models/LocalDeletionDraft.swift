import Foundation

struct LocalDeletionDraft: Codable, Equatable, Sendable {
    enum Action: String, Codable, Equatable, Sendable {
        case clearCompletedHistory
        case clearFailedAndCancelledHistory
        case clearDiagnostics
        case resetSettings
        case deleteSelectedMediaFile
    }

    enum DataCategory: String, Codable, Equatable, Sendable {
        case localJobRecords
        case thumbnailCacheFiles
        case diagnostics
        case settings
        case outputFolderBookmark
        case downloadedMediaFiles
    }

    var action: Action
    var jobRecordIDs: [UUID]
    var thumbnailCacheNames: [String]
    var selectedMediaFileName: String?
    var deletedData: [DataCategory]
    var retainedData: [DataCategory]
    var deletesDownloadedMedia: Bool
    var requiresSeparateMediaFileAction: Bool

    static func actionPreview(
        _ action: Action,
        selectedMediaFileURL: URL? = nil
    ) -> LocalDeletionDraft {
        switch action {
        case .clearCompletedHistory, .clearFailedAndCancelledHistory:
            return historyPreview(action: action, jobs: [])
        case .clearDiagnostics:
            return LocalDeletionDraft(
                action: action,
                jobRecordIDs: [],
                thumbnailCacheNames: [],
                selectedMediaFileName: nil,
                deletedData: [.diagnostics],
                retainedData: [.localJobRecords, .thumbnailCacheFiles, .downloadedMediaFiles, .settings],
                deletesDownloadedMedia: false,
                requiresSeparateMediaFileAction: true
            )
        case .resetSettings:
            return LocalDeletionDraft(
                action: action,
                jobRecordIDs: [],
                thumbnailCacheNames: [],
                selectedMediaFileName: nil,
                deletedData: [.settings, .outputFolderBookmark],
                retainedData: [.localJobRecords, .thumbnailCacheFiles, .downloadedMediaFiles, .diagnostics],
                deletesDownloadedMedia: false,
                requiresSeparateMediaFileAction: true
            )
        case .deleteSelectedMediaFile:
            return LocalDeletionDraft(
                action: action,
                jobRecordIDs: [],
                thumbnailCacheNames: [],
                selectedMediaFileName: selectedMediaFileURL?.lastPathComponent,
                deletedData: [.downloadedMediaFiles],
                retainedData: [.localJobRecords, .thumbnailCacheFiles, .settings, .diagnostics],
                deletesDownloadedMedia: true,
                requiresSeparateMediaFileAction: false
            )
        }
    }

    static func historyPreview(action: Action, jobs: [DownloadJob]) -> LocalDeletionDraft {
        let selectedJobs = jobs.filter { job in
            switch action {
            case .clearCompletedHistory:
                job.status == .completed
            case .clearFailedAndCancelledHistory:
                job.status == .failed || job.status == .cancelled
            case .clearDiagnostics, .resetSettings, .deleteSelectedMediaFile:
                false
            }
        }

        return LocalDeletionDraft(
            action: action,
            jobRecordIDs: selectedJobs.map(\.id),
            thumbnailCacheNames: selectedJobs.compactMap(thumbnailCacheName),
            selectedMediaFileName: nil,
            deletedData: [.localJobRecords, .thumbnailCacheFiles],
            retainedData: [.downloadedMediaFiles, .settings, .diagnostics],
            deletesDownloadedMedia: false,
            requiresSeparateMediaFileAction: true
        )
    }

    private static func thumbnailCacheName(from job: DownloadJob) -> String? {
        guard let path = job.thumbnailCachePath else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
