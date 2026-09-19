import Foundation
import XCTest
@testable import YTDownloaderPro2

final class PersistenceControllerTests: XCTestCase {
    func testRoundTripPersistsJobs() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        let jobs = [DownloadJob.fixture(title: "Example")]

        try await sut.saveJobs(jobs, flush: true)

        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded, jobs)
    }

    func testRoundTripPreservesBatchAnalysisPlaceholderMarker() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        let job = DownloadJob.fixture(status: .analyzing, awaitsBatchAnalysis: true)

        try await sut.saveJobs([job], flush: true)

        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded.first?.awaitsBatchAnalysis, true)
    }

    func testInterruptedActiveJobsRestoreAsPaused() async throws {
        let sut = PersistenceController(root: try temporaryDirectory())
        let jobs: [DownloadJob] = [
            .fixture(status: .analyzing),
            .fixture(status: .downloading),
            .fixture(status: .merging),
            .fixture(status: .queued),
            .fixture(status: .completed)
        ]

        let restored = await sut.recoverInterruptedJobs(jobs)

        XCTAssertEqual(restored.map(\.status), [.paused, .paused, .paused, .queued, .completed])
    }

    func testInterruptedBatchAnalysisPlaceholderRemainsAnalyzingForStoreRecovery() async throws {
        let sut = PersistenceController(root: try temporaryDirectory())
        let placeholder = DownloadJob.fixture(status: .analyzing, awaitsBatchAnalysis: true)

        let restored = await sut.recoverInterruptedJobs([placeholder])

        XCTAssertEqual(restored.first?.status, .analyzing)
        XCTAssertEqual(restored.first?.awaitsBatchAnalysis, true)
    }

    func testLoadingJobsRestoresInterruptedActiveJobsAsPaused() async throws {
        let sut = PersistenceController(root: try temporaryDirectory())
        try await sut.saveJobs([.fixture(status: .merging)], flush: true)

        let loaded = try await sut.loadJobs()

        XCTAssertEqual(loaded.map(\.status), [.paused])
    }

    func testSavingJobsStripsUserInfoFromRetainedMediaURLsBeforeDiskWrite() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        var job = DownloadJob.fixture(
            sourceURL: "https://disk-user:disk-pass@youtube.test/watch?v=disk",
            status: .completed
        )
        job.sourceMetadata = "https://meta-user:meta-pass@youtube.test/watch?v=disk"

        try await sut.saveJobs([job], flush: true)

        let storedData = try Data(contentsOf: root.appendingPathComponent("downloads.json"))
        let storedSnapshot = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(storedSnapshot.contains("disk-user"))
        XCTAssertFalse(storedSnapshot.contains("disk-pass"))
        XCTAssertFalse(storedSnapshot.contains("meta-user"))
        XCTAssertFalse(storedSnapshot.contains("meta-pass"))
        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded.first?.sourceURL, "https://youtube.test/watch?v=disk")
        XCTAssertEqual(loaded.first?.sourceMetadata, "https://youtube.test/watch?v=disk")
    }

    func testLoadingLegacySnapshotStripsUserInfoFromRetainedMediaURLs() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        var job = DownloadJob.fixture(
            sourceURL: "https://legacy-user:legacy-pass@youtube.test/watch?v=legacy",
            status: .queued
        )
        job.sourceMetadata = "https://legacy-meta:legacy-secret@youtube.test/watch?v=legacy"
        try writeSnapshot([job], to: root.appendingPathComponent("downloads.json"))

        let loaded = try await sut.loadJobs()

        XCTAssertEqual(loaded.first?.sourceURL, "https://youtube.test/watch?v=legacy")
        XCTAssertEqual(loaded.first?.sourceMetadata, "https://youtube.test/watch?v=legacy")
    }

    func testCorruptPrimaryUsesPreviousSnapshot() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        try await sut.saveJobs([.fixture(title: "Saved")], flush: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("downloads.json"))

        let loaded = try await sut.loadJobs()

        XCTAssertEqual(loaded.first?.title, "Saved")
    }

    func testLaterSavePreservesPriorSnapshotForRecovery() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)
        try await sut.saveJobs([.fixture(title: "First")], flush: true)
        try await sut.saveJobs([.fixture(title: "Second")], flush: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("downloads.json"))

        let loaded = try await sut.loadJobs()

        XCTAssertEqual(loaded.map(\.title), ["First"])
    }

    func testNonFlushSavesCoalesceToLatestSnapshot() async throws {
        let root = try temporaryDirectory()
        let sut = PersistenceController(root: root)

        try await sut.saveJobs([.fixture(title: "First")], flush: false)
        try await sut.saveJobs([.fixture(title: "Latest")], flush: false)
        try await Task.sleep(for: .milliseconds(100))

        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded.map(\.title), ["Latest"])
    }

    func testDeferredWriteFailureFlushPersistsLatestSnapshotBeforeReportingFailure() async throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("blocked-root")
        try Data("not-a-directory".utf8).write(to: root)
        let sut = PersistenceController(root: root)

        try await sut.saveJobs([.fixture(title: "First")], flush: false)
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.removeItem(at: root)

        do {
            try await sut.saveJobs([.fixture(title: "Latest")], flush: true)
            XCTFail("Expected a deferred write failure")
        } catch {
            XCTAssertEqual(error as? PersistenceControllerError, .deferredWriteFailed)
        }

        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded.map(\.title), ["Latest"])
    }

    func testHistoryRemovalMirrorsRecoverySnapshotEvenWhenReportingDeferredFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = DownloadJob.fixture(title: "Removed", status: .completed)
        let retained = DownloadJob.fixture(title: "Retained", status: .queued)
        let sut = PersistenceController(root: root)
        try await sut.saveJobs([removed, retained], flush: true)
        let blockedNext = root.appendingPathComponent("State/downloads.next")
        try FileManager.default.createDirectory(at: blockedNext, withIntermediateDirectories: false)
        try await sut.saveJobs([removed, retained], flush: false)
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.removeItem(at: blockedNext)

        do {
            try await sut.saveJobsAfterHistoryRemoval([retained])
            XCTFail("Expected the prior deferred failure to be reported")
        } catch {
            XCTAssertEqual(error as? PersistenceControllerError, .deferredWriteFailed)
        }

        try Data("corrupted primary".utf8).write(to: root.appendingPathComponent("downloads.json"))
        let recovered = try await PersistenceController(root: root).loadJobs()
        XCTAssertEqual(recovered.map(\.id), [retained.id])
    }

    func testFailedFlushRetryPreservesDeferredFailureAndLatestSnapshot() async throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("blocked-root")
        try Data("not-a-directory".utf8).write(to: root)
        let sut = PersistenceController(root: root)

        try await sut.saveJobs([.fixture(title: "First")], flush: false)
        try await Task.sleep(for: .milliseconds(100))

        do {
            try await sut.saveJobs([.fixture(title: "Latest")], flush: true)
            XCTFail("Expected the retry write to fail")
        } catch {
            XCTAssertFalse(error is PersistenceControllerError)
        }

        try FileManager.default.removeItem(at: root)
        do {
            try await sut.saveJobs([.fixture(title: "Latest")], flush: true)
            XCTFail("Expected the original deferred write failure to be reported")
        } catch {
            XCTAssertEqual(error as? PersistenceControllerError, .deferredWriteFailed)
        }

        let loaded = try await sut.loadJobs()
        XCTAssertEqual(loaded.map(\.title), ["Latest"])
    }

    func testSettingsStoreLoadsLegacySettingsWithDefaultsAndClampsConcurrency() throws {
        let (defaults, key, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("{\"maximumConcurrentDownloads\":99}".utf8), forKey: key)
        let sut = AppSettingsStore(defaults: defaults, key: key)

        let settings = sut.load()

        XCTAssertEqual(settings.maximumConcurrentDownloads, 10)
        XCTAssertNil(settings.languageOverride)
        XCTAssertEqual(settings.defaultOptions, .defaults)
        XCTAssertTrue(settings.automaticallyCheckForUpdates)
    }

    func testSettingsStoreClampsConcurrencyBeforeSaving() throws {
        let (defaults, key, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sut = AppSettingsStore(defaults: defaults, key: key)
        var settings = AppSettings()
        settings.maximumConcurrentDownloads = 99

        sut.save(settings)

        XCTAssertEqual(sut.load().maximumConcurrentDownloads, 10)
    }

    func testSelectedOutputDirectoryBookmarkIsStoredInDefaultOptions() throws {
        let folder = try temporaryDirectory()
        let bookmark = Data("bookmark".utf8)
        let scope = SecurityScopeRecorder()
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in bookmark },
            resolveBookmark: { _ in .init(url: folder, isStale: false) },
            startAccessingSecurityScopedResource: { _ in
                scope.startCount += 1
                return true
            },
            stopAccessingSecurityScopedResource: { _ in
                scope.stopCount += 1
            }
        )
        var settings = AppSettings()

        try settings.setDefaultOutputDirectory(folder, bookmarks: bookmarks)

        XCTAssertEqual(settings.defaultOptions.outputDirectoryBookmark, bookmark)
        XCTAssertEqual(settings.defaultOptions.outputDirectoryDisplayPath, folder.path)
        let access = try settings.beginDefaultOutputDirectoryAccess(bookmarks: bookmarks)
        XCTAssertEqual(access.url, folder)
        XCTAssertEqual(scope.startCount, 1)
        XCTAssertEqual(scope.stopCount, 0)

        access.stopAccessing()
        access.stopAccessing()
        XCTAssertEqual(scope.stopCount, 1)
    }

    func testStaleOutputDirectoryBookmarkNeedsReselection() throws {
        let bookmark = Data("stale-bookmark".utf8)
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in bookmark },
            resolveBookmark: { _ in .init(url: URL(fileURLWithPath: "/tmp/stale"), isStale: true) }
        )
        var settings = AppSettings()
        try settings.setDefaultOutputDirectory(URL(fileURLWithPath: "/tmp/stale"), bookmarks: bookmarks)

        XCTAssertThrowsError(try settings.beginDefaultOutputDirectoryAccess(bookmarks: bookmarks)) { error in
            XCTAssertEqual(error as? OutputDirectoryBookmarkError, .needsReselection)
        }
    }

    func testOutputDirectoryAccessStopsWhenScopeExits() throws {
        let folder = try temporaryDirectory()
        let bookmark = Data("scoped-bookmark".utf8)
        let scope = SecurityScopeRecorder()
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in bookmark },
            resolveBookmark: { _ in .init(url: folder, isStale: false) },
            startAccessingSecurityScopedResource: { _ in
                scope.startCount += 1
                return true
            },
            stopAccessingSecurityScopedResource: { _ in
                scope.stopCount += 1
            }
        )
        var settings = AppSettings()
        try settings.setDefaultOutputDirectory(folder, bookmarks: bookmarks)

        try settings.withDefaultOutputDirectoryAccess(bookmarks: bookmarks) { url in
            XCTAssertEqual(url, folder)
            XCTAssertEqual(scope.startCount, 1)
            XCTAssertEqual(scope.stopCount, 0)
        }

        XCTAssertEqual(scope.stopCount, 1)
    }

    func testUnreadableOutputDirectoryBookmarkNeedsReselection() throws {
        let bookmark = Data("unreadable-bookmark".utf8)
        let scope = SecurityScopeRecorder()
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in bookmark },
            resolveBookmark: { _ in .init(url: URL(fileURLWithPath: "/tmp/unreadable"), isStale: false) },
            startAccessingSecurityScopedResource: { _ in
                scope.startCount += 1
                return false
            },
            stopAccessingSecurityScopedResource: { _ in
                scope.stopCount += 1
            }
        )
        var settings = AppSettings()
        try settings.setDefaultOutputDirectory(URL(fileURLWithPath: "/tmp/unreadable"), bookmarks: bookmarks)

        XCTAssertThrowsError(try settings.beginDefaultOutputDirectoryAccess(bookmarks: bookmarks)) { error in
            XCTAssertEqual(error as? OutputDirectoryBookmarkError, .needsReselection)
        }
        XCTAssertEqual(scope.startCount, 1)
        XCTAssertEqual(scope.stopCount, 0)
    }

    private func makeDefaults() throws -> (UserDefaults, String, String) {
        let suiteName = "PersistenceControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, "app-settings", suiteName)
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    var startCount = 0
    var stopCount = 0
}

private struct TestJobsSnapshot: Codable {
    let schemaVersion: Int
    let jobs: [DownloadJob]
}

private func writeSnapshot(_ jobs: [DownloadJob], to url: URL) throws {
    let snapshot = TestJobsSnapshot(schemaVersion: 1, jobs: jobs)
    let data = try JSONEncoder().encode(snapshot)
    try data.write(to: url)
}
