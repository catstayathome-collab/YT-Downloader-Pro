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

    func testLoadingJobsRestoresInterruptedActiveJobsAsPaused() async throws {
        let sut = PersistenceController(root: try temporaryDirectory())
        try await sut.saveJobs([.fixture(status: .merging)], flush: true)

        let loaded = try await sut.loadJobs()

        XCTAssertEqual(loaded.map(\.status), [.paused])
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
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in bookmark },
            resolveBookmark: { _ in .init(url: folder, isStale: false) }
        )
        var settings = AppSettings()

        try settings.setDefaultOutputDirectory(folder, bookmarks: bookmarks)

        XCTAssertEqual(settings.defaultOptions.outputDirectoryBookmark, bookmark)
        XCTAssertEqual(settings.defaultOptions.outputDirectoryDisplayPath, folder.path)
        XCTAssertEqual(try settings.resolvedDefaultOutputDirectory(bookmarks: bookmarks), folder)
    }

    func testStaleOutputDirectoryBookmarkNeedsReselection() throws {
        let bookmark = Data("stale-bookmark".utf8)
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in bookmark },
            resolveBookmark: { _ in .init(url: URL(fileURLWithPath: "/tmp/stale"), isStale: true) }
        )
        var settings = AppSettings()
        try settings.setDefaultOutputDirectory(URL(fileURLWithPath: "/tmp/stale"), bookmarks: bookmarks)

        XCTAssertThrowsError(try settings.resolvedDefaultOutputDirectory(bookmarks: bookmarks)) { error in
            XCTAssertEqual(error as? OutputDirectoryBookmarkError, .needsReselection)
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String, String) {
        let suiteName = "PersistenceControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, "app-settings", suiteName)
    }
}
