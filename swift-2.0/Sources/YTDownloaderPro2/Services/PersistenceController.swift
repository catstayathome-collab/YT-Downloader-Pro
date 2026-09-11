import Foundation

enum PersistenceControllerError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case noRecoverableSnapshot
    case deferredWriteFailed
}

actor PersistenceController {
    private struct JobsSnapshot: Codable {
        let schemaVersion: Int
        let jobs: [DownloadJob]
    }

    private static let schemaVersion = 1
    private static let coalescingDelay: Duration = .milliseconds(50)

    private let root: URL
    private let fileManager: FileManager
    private var pendingJobs: [DownloadJob]?
    private var deferredSaveTask: Task<Void, Never>?
    private var hasDeferredWriteFailure = false

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func loadJobs() throws -> [DownloadJob] {
        if let jobs = loadSnapshotIfPresent(at: primaryURL) {
            return recoverInterruptedJobs(jobs)
        }
        if let jobs = loadSnapshotIfPresent(at: previousURL) {
            return recoverInterruptedJobs(jobs)
        }

        if fileManager.fileExists(atPath: primaryURL.path) || fileManager.fileExists(atPath: previousURL.path) {
            throw PersistenceControllerError.noRecoverableSnapshot
        }
        return []
    }

    func saveJobs(_ jobs: [DownloadJob], flush: Bool) throws {
        pendingJobs = jobs

        if flush {
            deferredSaveTask?.cancel()
            deferredSaveTask = nil
            let deferredWriteFailure = hasDeferredWriteFailure
            let latestJobs = pendingJobs ?? jobs
            try persist(latestJobs)
            pendingJobs = nil
            if deferredWriteFailure {
                hasDeferredWriteFailure = false
                throw PersistenceControllerError.deferredWriteFailed
            }
            return
        }

        guard deferredSaveTask == nil else {
            return
        }

        deferredSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.coalescingDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.persistCoalescedJobs()
        }
    }

    func recoverInterruptedJobs(_ jobs: [DownloadJob]) -> [DownloadJob] {
        jobs.map { job in
            var restored = job.scrubbingRetainedMediaURLCredentials()
            if restored.status.isActive, !restored.awaitsBatchAnalysis {
                restored.status = .paused
            }
            return restored
        }
    }

    private var stateDirectoryURL: URL {
        root.appendingPathComponent("State", isDirectory: true)
    }

    private var primaryURL: URL {
        root.appendingPathComponent("downloads.json")
    }

    private var nextURL: URL {
        stateDirectoryURL.appendingPathComponent("downloads.next")
    }

    private var previousURL: URL {
        stateDirectoryURL.appendingPathComponent("downloads.previous")
    }

    private func persistCoalescedJobs() {
        deferredSaveTask = nil
        guard let jobs = pendingJobs else {
            return
        }

        do {
            try persist(jobs)
            pendingJobs = nil
        } catch {
            hasDeferredWriteFailure = true
        }
    }

    private func persist(_ jobs: [DownloadJob]) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)

        let snapshot = JobsSnapshot(
            schemaVersion: Self.schemaVersion,
            jobs: jobs.map { $0.scrubbingRetainedMediaURLCredentials() }
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: nextURL, options: .atomic)

        if fileManager.fileExists(atPath: primaryURL.path) {
            let existingData = try Data(contentsOf: primaryURL)
            if (try? decodeSnapshot(existingData)) != nil {
                try existingData.write(to: previousURL, options: .atomic)
            }
            _ = try fileManager.replaceItemAt(primaryURL, withItemAt: nextURL)
        } else {
            try fileManager.moveItem(at: nextURL, to: primaryURL)
        }

        if !fileManager.fileExists(atPath: previousURL.path) {
            let primaryData = try Data(contentsOf: primaryURL)
            try primaryData.write(to: previousURL, options: .atomic)
        }
    }

    private func loadSnapshotIfPresent(at url: URL) -> [DownloadJob]? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? decodeSnapshot(data) else {
            return nil
        }
        return snapshot.jobs
    }

    private func decodeSnapshot(_ data: Data) throws -> JobsSnapshot {
        let snapshot = try JSONDecoder().decode(JobsSnapshot.self, from: data)
        guard snapshot.schemaVersion == Self.schemaVersion else {
            throw PersistenceControllerError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }
}
