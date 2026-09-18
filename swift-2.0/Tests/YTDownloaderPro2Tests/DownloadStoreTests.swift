import AppKit
import Foundation
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class DownloadStoreTests: XCTestCase {
    func testFilteredJobsShowNewestRecordsFirstWithoutReorderingQueueStorage() throws {
        let oldest = DownloadJob(
            sourceURL: "https://example.com/oldest",
            title: "Oldest",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newest = DownloadJob(
            sourceURL: "https://example.com/newest",
            title: "Newest",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let middle = DownloadJob(
            sourceURL: "https://example.com/middle",
            title: "Middle",
            status: .queued,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let fixture = try StoreFixture(jobs: [oldest, newest, middle])
        defer { fixture.cleanUp() }

        XCTAssertEqual(fixture.store.filteredJobs.map(\.id), [newest.id, middle.id, oldest.id])
        XCTAssertEqual(fixture.store.jobs.map(\.id), [oldest.id, newest.id, middle.id])

        fixture.store.sidebarSection = .completed

        XCTAssertEqual(fixture.store.filteredJobs.map(\.id), [newest.id, oldest.id])
        XCTAssertEqual(fixture.store.jobs.map(\.id), [oldest.id, newest.id, middle.id])
    }

    func testAutomaticTransientUpdateFailureRemainsUnpublished() async throws {
        let updater = StoreUpdateChecker(result: .failed(.silentTransient))
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }

        await fixture.store.checkForUpdates(manual: false)

        let calls = await updater.manualArguments()
        XCTAssertNil(fixture.store.updateResult)
        XCTAssertEqual(calls, [false])
    }

    func testManualUpdateFailureIsPublishedForActionableUI() async throws {
        let updater = StoreUpdateChecker(result: .failed(.actionableNetwork))
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }

        await fixture.store.checkForUpdates(manual: true)

        let calls = await updater.manualArguments()
        XCTAssertEqual(fixture.store.updateResult, .failed(.actionableNetwork))
        XCTAssertEqual(
            fixture.store.manualUpdateNotice?.result,
            .failed(.actionableNetwork)
        )
        XCTAssertNil(fixture.store.automaticUpdateNotice)
        XCTAssertEqual(calls, [true])
    }

    func testAutomaticCheckPublishesOnlyAvailableOrUnsupportedResults() async throws {
        let hiddenResults: [UpdateResult] = [
            .upToDate,
            .failed(.silentTransient),
            .failed(.actionableNetwork),
            .failed(.invalidManifest)
        ]

        for result in hiddenResults {
            let updater = StoreUpdateChecker(result: result)
            let fixture = try StoreFixture(updateChecker: updater)
            await fixture.store.checkForUpdates(manual: false)
            XCTAssertNil(fixture.store.updateResult, "automatic result: \(result)")
            XCTAssertNil(fixture.store.automaticUpdateNotice)
            fixture.cleanUp()
        }

        for result in [UpdateResult.available(.fixture()), .unsupportedOS(.fixture())] {
            let updater = StoreUpdateChecker(result: result)
            let fixture = try StoreFixture(updateChecker: updater)
            await fixture.store.checkForUpdates(manual: false)
            XCTAssertEqual(fixture.store.updateResult, result)
            XCTAssertEqual(fixture.store.automaticUpdateNotice?.result, result)
            XCTAssertNil(fixture.store.manualUpdateNotice)
            fixture.cleanUp()
        }
    }

    func testDuplicateAutomaticChecksShareOneRequest() async throws {
        let updater = ControlledUpdateChecker()
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }

        let first = Task { await fixture.store.checkForUpdates(manual: false) }
        try await updater.waitForCallCount(1)
        let second = Task { await fixture.store.checkForUpdates(manual: false) }
        try await Task.sleep(for: .milliseconds(20))

        let callsBeforeResolution = await updater.manualArguments()
        XCTAssertEqual(callsBeforeResolution, [false])
        await updater.resolveCall(at: 0, with: .available(.fixture()))
        await first.value
        await second.value
        XCTAssertEqual(fixture.store.updateResult, .available(.fixture()))
    }

    func testUpdateNoticesDismissOnlyTheirMatchingGeneration() async throws {
        let updater = StoreUpdateChecker(result: .upToDate)
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }

        await fixture.store.checkForUpdates(manual: true)
        let notice = try XCTUnwrap(fixture.store.manualUpdateNotice)

        fixture.store.dismissManualUpdateNotice(id: notice.id + 1)
        XCTAssertEqual(fixture.store.manualUpdateNotice, notice)
        fixture.store.dismissManualUpdateNotice(id: notice.id)
        XCTAssertNil(fixture.store.manualUpdateNotice)
    }

    func testManualCheckSupersedesStaleAutomaticCompletion() async throws {
        let updater = ControlledUpdateChecker()
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }

        let automatic = Task { await fixture.store.checkForUpdates(manual: false) }
        try await updater.waitForCallCount(1)
        let manual = Task { await fixture.store.checkForUpdates(manual: true) }
        try await updater.waitForCallCount(2)

        await updater.resolveCall(at: 1, with: .failed(.actionableNetwork))
        await manual.value
        XCTAssertEqual(fixture.store.updateResult, .failed(.actionableNetwork))

        await updater.resolveCall(at: 0, with: .upToDate)
        await automatic.value
        XCTAssertEqual(fixture.store.updateResult, .failed(.actionableNetwork))
        let calls = await updater.manualArguments()
        XCTAssertEqual(calls, [false, true])
    }

    func testDisabledAutomaticUpdateCheckDoesNotCallService() async throws {
        let updater = StoreUpdateChecker(result: .upToDate)
        let fixture = try StoreFixture(
            settings: AppSettings(automaticallyCheckForUpdates: false),
            updateChecker: updater
        )
        defer { fixture.cleanUp() }

        await fixture.store.checkForUpdates(manual: false)

        let calls = await updater.manualArguments()
        XCTAssertEqual(calls, [])
    }

    func testAppLifecycleStartsAutomaticUpdateCheckAfterLaunch() async throws {
        let updater = StoreUpdateChecker(result: .upToDate)
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }
        let lifecycle = AppLifecycle(store: fixture.store)

        lifecycle.startAutomaticUpdateCheck()

        try await updater.waitForCallCount(1)
        let calls = await updater.manualArguments()
        XCTAssertEqual(calls, [false])
    }

    func testUnrecoverablePersistenceLoadPublishesLocalizedRecoveryFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-json".utf8).write(to: root.appendingPathComponent("downloads.json"))
        let suiteName = "DownloadStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DownloadStore.live(
            applicationSupportRoot: root,
            settingsStore: AppSettingsStore(defaults: defaults)
        )

        try await waitUntil("persistence recovery failure") {
            if case .failed = store.analysisState { return true }
            return false
        }

        guard case let .failed(failure) = store.analysisState else {
            return XCTFail("Expected persistence recovery failure")
        }
        XCTAssertEqual(failure.category, .persistenceRecovery)
        try await store.prepareToQuit()
    }

    func testSelectingOutputDirectoryCreatesBookmarkThroughInjectedStoreBoundary() throws {
        let directory = URL(fileURLWithPath: "/chosen/downloads", isDirectory: true)
        let bookmark = Data("stored-bookmark".utf8)
        let fixture = try StoreFixture(
            bookmarks: OutputDirectoryBookmarkService(
                makeBookmark: { requestedURL in
                    guard requestedURL == directory else { throw BookmarkFixtureError.unexpectedURL }
                    return bookmark
                },
                resolveBookmark: { _ in .init(url: directory, isStale: false) }
            )
        )
        defer { fixture.cleanUp() }

        let selected = try fixture.store.optionsBySelectingOutputDirectory(directory, in: .defaults)

        XCTAssertEqual(selected.outputDirectoryBookmark, bookmark)
        XCTAssertEqual(selected.outputDirectoryDisplayPath, directory.path)
    }

    func testSelectingOutputDirectoryPersistsItAsTheNextDownloadDefault() throws {
        let directory = URL(fileURLWithPath: "/chosen/remembered-downloads", isDirectory: true)
        let bookmark = Data("remembered-bookmark".utf8)
        let suiteName = "DownloadStoreTests-remember-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let fixture = try StoreFixture(
            bookmarks: OutputDirectoryBookmarkService(
                makeBookmark: { _ in bookmark },
                resolveBookmark: { _ in .init(url: directory, isStale: false) }
            ),
            settingsStore: settingsStore
        )
        defer { fixture.cleanUp() }
        var currentDownloadOptions = DownloadOptions.defaults
        currentDownloadOptions.outputKind = .mp3

        let selected = try fixture.store.optionsBySelectingOutputDirectory(
            directory,
            in: currentDownloadOptions
        )

        XCTAssertEqual(selected.outputKind, .mp3)
        XCTAssertEqual(fixture.store.settings.defaultOptions.outputKind, .mp4)
        XCTAssertEqual(fixture.store.settings.defaultOptions.outputDirectoryBookmark, bookmark)
        XCTAssertEqual(fixture.store.settings.defaultOptions.outputDirectoryDisplayPath, directory.path)
        XCTAssertEqual(settingsStore.load(), fixture.store.settings)
    }

    func testSelectingOutputDirectoryReportsActionableFailureWithoutMutatingOptions() throws {
        let fixture = try StoreFixture(
            bookmarks: OutputDirectoryBookmarkService(
                makeBookmark: { _ in throw BookmarkFixtureError.creationFailed },
                resolveBookmark: { _ in throw BookmarkFixtureError.creationFailed }
            )
        )
        defer { fixture.cleanUp() }
        let original = DownloadOptions.defaults

        XCTAssertThrowsError(
            try fixture.store.optionsBySelectingOutputDirectory(
                URL(fileURLWithPath: "/unavailable", isDirectory: true),
                in: original
            )
        ) { error in
            XCTAssertEqual(error as? OutputDirectorySelectionError, .bookmarkCreationFailed)
        }
        XCTAssertEqual(original, .defaults)
    }

    func testAnalysisStopsAtToolchainGateAndPublishesLocalizedConverterFailure() async throws {
        let analyzer = AnalysisRecorder(result: .video(.fixture()))
        let gate = StoreToolchainGate(results: [
            .failure(DownloadFailure(category: .bundledConverterUnavailable))
        ])
        let fixture = try StoreFixture(
            analysis: { url, options in try await analyzer.analyze(url: url, options: options) },
            toolchainValidator: gate
        )
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/video")

        let requestedURLs = await analyzer.recordedURLs()
        XCTAssertEqual(requestedURLs, [])
        guard case let .failed(failure) = fixture.store.analysisState else {
            return XCTFail("Expected a toolchain failure")
        }
        XCTAssertEqual(failure.category, .bundledConverterUnavailable)
        let gateArguments = await gate.forcedArguments()
        XCTAssertEqual(gateArguments, [false])
    }

    func testAnalysisExecutionFailureForcesToolchainRecheckAndPrefersItsTypedFailure() async throws {
        let gate = StoreToolchainGate(results: [
            .success(.fixture),
            .failure(DownloadFailure(category: .bundledConverterUnavailable))
        ])
        let fixture = try StoreFixture(
            analysis: { _, _ in
                throw DownloadFailure(category: .bundledDownloaderUnavailable)
            },
            toolchainValidator: gate
        )
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/video")

        guard case let .failed(failure) = fixture.store.analysisState else {
            return XCTFail("Expected a toolchain failure")
        }
        XCTAssertEqual(failure.category, .bundledConverterUnavailable)
        let gateArguments = await gate.forcedArguments()
        XCTAssertEqual(gateArguments, [false, true])
    }

    func testPlaylistBatchCreatesOneJobPerSelectedEntryInPlaylistOrder() async throws {
        let fixture = try StoreFixture(analysis: .playlist(.fixture(entryCount: 3)))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/playlist")
        await fixture.store.addPlaylistEntries(selectedIDs: ["1", "3"], options: .defaults)

        XCTAssertEqual(fixture.store.jobs.map(\.sourceURL), [
            "https://youtube.test/watch?v=1",
            "https://youtube.test/watch?v=3"
        ])
    }

    func testSingleURLSubmissionRetainsExistingAnalysisSheetFlow() async throws {
        let fixture = try StoreFixture(analysis: .video(.fixture(title: "Single video")))
        defer { fixture.cleanUp() }

        let result = await fixture.store.submitURLInput("https://youtube.test/single")

        XCTAssertEqual(result, URLInputSubmissionResult(acceptedCount: 1, rejectedCount: 0, duplicateCount: 0))
        XCTAssertTrue(fixture.store.jobs.isEmpty)
        guard case let .video(video) = fixture.store.analysisState else {
            return XCTFail("Expected the existing single-video analysis presentation")
        }
        XCTAssertEqual(video.title, "Single video")
    }

    func testBatchSubmissionCreatesPlaceholdersThenAnalyzesFIFOAndStartsFirstSuccess() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) },
            coordinatorLimit: 2
        )
        defer { fixture.cleanUp() }

        let result = await fixture.store.submitURLInput(
            "https://youtube.test/one\nhttps://youtube.test/two"
        )
        let placeholderIDs = fixture.store.jobs.map(\.id)

        XCTAssertEqual(result.acceptedCount, 2)
        XCTAssertEqual(fixture.store.jobs.map(\.sourceURL), [
            "https://youtube.test/one",
            "https://youtube.test/two"
        ])
        XCTAssertEqual(fixture.store.jobs.map(\.status), [.analyzing, .analyzing])
        XCTAssertEqual(fixture.store.jobs.map(\.awaitsBatchAnalysis), [true, true])
        try await analysis.waitForRequestCount(1)
        let firstRequestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(firstRequestedURLs, ["https://youtube.test/one"])

        await analysis.succeed(
            request: 0,
            with: .video(.fixture(sourceURL: "https://youtube.test/one", title: "First"))
        )
        try await analysis.waitForRequestCount(2)
        try await fixture.runner.waitForStart(of: placeholderIDs[0])

        let allRequestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(allRequestedURLs, [
            "https://youtube.test/one",
            "https://youtube.test/two"
        ])
        XCTAssertEqual(fixture.store.jobs[0].id, placeholderIDs[0])
        XCTAssertFalse(fixture.store.jobs[0].awaitsBatchAnalysis)
        XCTAssertTrue(fixture.store.jobs[1].awaitsBatchAnalysis)

        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/two", title: "Second"))
        )
        try await fixture.runner.waitForStart(of: placeholderIDs[1])
        await fixture.store.cancelActiveAndWaiting()
    }

    func testBatchFailureDoesNotPreventFollowingURLAnalysis() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) }
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/fails https://youtube.test/succeeds"
        )
        try await analysis.waitForRequestCount(1)
        await analysis.fail(
            request: 0,
            with: DownloadFailure(category: .networkUnavailable, technicalDetail: "offline")
        )
        try await analysis.waitForRequestCount(2)

        XCTAssertEqual(fixture.store.jobs[0].status, .failed)
        XCTAssertEqual(fixture.store.jobs[0].failure?.category, .networkUnavailable)
        XCTAssertFalse(fixture.store.jobs[0].awaitsBatchAnalysis)
        XCTAssertTrue(fixture.store.jobs[1].awaitsBatchAnalysis)

        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/succeeds"))
        )
        let secondID = fixture.store.jobs[1].id
        try await fixture.runner.waitForStart(of: secondID)
        await fixture.store.cancel(secondID)
    }

    func testBatchPlaylistReplacesPlaceholderWithAvailableEntriesInPlaylistOrder() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) },
            coordinatorLimit: 3
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/playlist https://youtube.test/video"
        )
        let playlistPlaceholderID = try XCTUnwrap(fixture.store.jobs.first?.id)
        try await analysis.waitForRequestCount(1)
        var playlist = PlaylistAnalysis.fixture(entryCount: 3)
        playlist.entries[1].isAvailable = false
        await analysis.succeed(request: 0, with: .playlist(playlist))
        try await analysis.waitForRequestCount(2)

        XCTAssertFalse(fixture.store.jobs.contains(where: { $0.id == playlistPlaceholderID }))
        XCTAssertEqual(Array(fixture.store.jobs.prefix(2)).map(\.sourceURL), [
            "https://youtube.test/watch?v=1",
            "https://youtube.test/watch?v=3"
        ])
        XCTAssertTrue(fixture.store.jobs.prefix(2).allSatisfy { !$0.awaitsBatchAnalysis })

        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/video"))
        )
        try await fixture.runner.waitForStart(of: fixture.store.jobs.last!.id)
        await fixture.store.cancelActiveAndWaiting()
    }

    func testBatchPlaylistEntriesStayContiguousAboveTheFollowingURLInVisibleOrder() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) },
            coordinatorLimit: 4
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/playlist https://youtube.test/following"
        )
        try await analysis.waitForRequestCount(1)
        await analysis.succeed(request: 0, with: .playlist(.fixture(entryCount: 3)))
        try await analysis.waitForRequestCount(2)

        XCTAssertEqual(fixture.store.filteredJobs.map(\.sourceURL), [
            "https://youtube.test/watch?v=1",
            "https://youtube.test/watch?v=2",
            "https://youtube.test/watch?v=3",
            "https://youtube.test/following"
        ])

        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/following"))
        )
        await fixture.store.cancelActiveAndWaiting()
    }

    func testCancellingWaitingBatchPlaceholderPreventsItsMetadataRequest() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) }
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/current https://youtube.test/waiting"
        )
        try await analysis.waitForRequestCount(1)
        let currentID = fixture.store.jobs[0].id
        let waitingID = fixture.store.jobs[1].id

        await fixture.store.cancel(waitingID)

        XCTAssertEqual(fixture.store.jobs[1].status, .cancelled)
        XCTAssertTrue(fixture.store.jobs[1].awaitsBatchAnalysis)
        await analysis.succeed(
            request: 0,
            with: .video(.fixture(sourceURL: "https://youtube.test/current"))
        )
        try await fixture.runner.waitForStart(of: currentID)
        try await Task.sleep(for: .milliseconds(20))
        let requestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(requestedURLs, ["https://youtube.test/current"])
        await fixture.store.cancel(currentID)
    }

    func testCancellingCurrentBatchPlaceholderAdvancesToNextURL() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) }
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/current https://youtube.test/next"
        )
        try await analysis.waitForRequestCount(1)
        let currentID = fixture.store.jobs[0].id
        let nextID = fixture.store.jobs[1].id

        await fixture.store.cancel(currentID)
        try await analysis.waitForCancellationCount(1)

        XCTAssertEqual(fixture.store.jobs[0].status, .cancelled)
        XCTAssertTrue(fixture.store.jobs[0].awaitsBatchAnalysis)
        await analysis.succeed(
            request: 0,
            with: .video(.fixture(sourceURL: "https://youtube.test/current"))
        )
        try await analysis.waitForRequestCount(2)
        let requestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(requestedURLs, [
            "https://youtube.test/current",
            "https://youtube.test/next"
        ])
        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/next"))
        )
        try await fixture.runner.waitForStart(of: nextID)
        await fixture.store.cancel(nextID)
    }

    func testReAddingCancelledBatchPlaceholderRunsMetadataAnalysisBeforeDownload() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) },
            coordinatorLimit: 2
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/current https://youtube.test/re-added"
        )
        try await analysis.waitForRequestCount(1)
        let currentID = fixture.store.jobs[0].id
        let cancelledID = fixture.store.jobs[1].id
        await fixture.store.cancel(cancelledID)

        await fixture.store.reAdd(cancelledID)
        let replacement = try XCTUnwrap(fixture.store.jobs.last)
        XCTAssertNotEqual(replacement.id, cancelledID)
        XCTAssertEqual(replacement.status, .analyzing)
        XCTAssertTrue(replacement.awaitsBatchAnalysis)

        await analysis.succeed(
            request: 0,
            with: .video(.fixture(sourceURL: "https://youtube.test/current"))
        )
        try await fixture.runner.waitForStart(of: currentID)
        try await analysis.waitForRequestCount(2)
        let requestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(requestedURLs, [
            "https://youtube.test/current",
            "https://youtube.test/re-added"
        ])

        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/re-added"))
        )
        try await fixture.runner.waitForStart(of: replacement.id)
        await fixture.store.cancelActiveAndWaiting()
    }

    func testRecoveredBatchPlaceholdersResumeMetadataAnalysisInStoredOrder() async throws {
        let first = DownloadJob.fixture(
            sourceURL: "https://youtube.test/first",
            status: .analyzing,
            awaitsBatchAnalysis: true
        )
        let second = DownloadJob.fixture(
            sourceURL: "https://youtube.test/second",
            status: .analyzing,
            awaitsBatchAnalysis: true
        )
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            jobs: [first, second],
            analysis: { url, options in try await analysis.analyze(url: url, options: options) }
        )
        defer { fixture.cleanUp() }

        try await analysis.waitForRequestCount(1)
        XCTAssertEqual(fixture.store.jobs.map(\.status), [.analyzing, .analyzing])
        let firstRequestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(firstRequestedURLs, ["https://youtube.test/first"])
        await analysis.succeed(
            request: 0,
            with: .video(.fixture(sourceURL: "https://youtube.test/first"))
        )
        try await analysis.waitForRequestCount(2)
        let allRequestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(allRequestedURLs, [
            "https://youtube.test/first",
            "https://youtube.test/second"
        ])
        await analysis.succeed(
            request: 1,
            with: .video(.fixture(sourceURL: "https://youtube.test/second"))
        )
        await fixture.store.cancelActiveAndWaiting()
    }

    func testQuitCancelsAndJoinsCurrentBatchAnalysisWithoutApplyingItsResult() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(
            analysis: { url, options in try await analysis.analyze(url: url, options: options) }
        )
        defer { fixture.cleanUp() }

        _ = await fixture.store.submitURLInput(
            "https://youtube.test/current https://youtube.test/waiting"
        )
        try await analysis.waitForRequestCount(1)
        let quit = Task { try await fixture.store.prepareToQuit() }
        try await analysis.waitForCancellationCount(1)
        await analysis.succeed(
            request: 0,
            with: .video(.fixture(sourceURL: "https://youtube.test/current", title: "Stale"))
        )
        try await quit.value

        XCTAssertEqual(fixture.store.jobs.map(\.title), [
            L10n.string(.downloadCenterBatchAnalyzingTitle, locale: fixture.store.settings.locale),
            L10n.string(.downloadCenterBatchAnalyzingTitle, locale: fixture.store.settings.locale)
        ])
        XCTAssertTrue(fixture.store.jobs.allSatisfy { $0.awaitsBatchAnalysis })
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.analyzing, .analyzing])
        XCTAssertTrue(persisted.allSatisfy { $0.awaitsBatchAnalysis })
    }

    func testAddingVideoAutomaticallyStartsOnlyTheNewJob() async throws {
        let retainedQueuedJob = DownloadJob.fixture(title: "Retained queued job")
        let fixture = try StoreFixture(
            jobs: [retainedQueuedJob],
            analysis: .video(.fixture(title: "New video"))
        )
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/new-video")
        await fixture.store.addVideo(options: .defaults)
        let addedJob = try XCTUnwrap(fixture.store.jobs.last)
        try await fixture.runner.waitForStart(of: addedJob.id)

        let startedIDs = await fixture.runner.startedIDs()
        XCTAssertEqual(startedIDs, [addedJob.id])
        XCTAssertEqual(fixture.store.jobs.first(where: { $0.id == retainedQueuedJob.id })?.status, .queued)
        await fixture.store.cancel(addedJob.id)
    }

    func testAddingVideoScrubsAnalyzerReturnedUserInfoBeforePersistingOrStarting() async throws {
        let analysis = VideoAnalysis.fixture(
            sourceURL: "https://analysis-user:analysis-pass@youtube.test/watch?v=video"
        )
        let fixture = try StoreFixture(analysis: .video(analysis))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/request")
        await fixture.store.addVideo(options: .defaults)
        let addedJob = try XCTUnwrap(fixture.store.jobs.first)
        try await fixture.runner.waitForStart(of: addedJob.id)

        XCTAssertEqual(addedJob.sourceURL, "https://youtube.test/watch?v=video")
        XCTAssertEqual(addedJob.sourceMetadata, "https://youtube.test/watch?v=video")
        let startedSourceURLs = await fixture.runner.startedSourceURLs()
        XCTAssertEqual(startedSourceURLs[addedJob.id], "https://youtube.test/watch?v=video")
    }

    func testAddingPlaylistAutomaticallyStartsOnlyTheNewBatchInSelectionOrder() async throws {
        let retainedQueuedJob = DownloadJob.fixture(title: "Retained queued job")
        let fixture = try StoreFixture(
            jobs: [retainedQueuedJob],
            analysis: .playlist(.fixture(entryCount: 3)),
            coordinatorLimit: 1
        )
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/playlist")
        await fixture.store.addPlaylistEntries(selectedIDs: ["1", "3"], options: .defaults)
        let addedJobs = Array(fixture.store.jobs.dropFirst())
        XCTAssertEqual(addedJobs.map(\.sourceURL), [
            "https://youtube.test/watch?v=1",
            "https://youtube.test/watch?v=3"
        ])

        try await fixture.runner.waitForStart(of: addedJobs[0].id)
        let firstStartedIDs = await fixture.runner.startedIDs()
        XCTAssertEqual(firstStartedIDs, [addedJobs[0].id])
        await fixture.store.cancel(addedJobs[0].id)
        try await fixture.runner.waitForStart(of: addedJobs[1].id)

        let allStartedIDs = await fixture.runner.startedIDs()
        XCTAssertEqual(allStartedIDs, addedJobs.map(\.id))
        XCTAssertFalse(allStartedIDs.contains(retainedQueuedJob.id))
        await fixture.store.cancel(addedJobs[1].id)
    }

    func testAddingPlaylistScrubsAnalyzerReturnedUserInfoBeforePersistingOrStarting() async throws {
        let entry = PlaylistEntry(
            id: "unsafe-entry",
            sourceURL: "https://playlist-user:playlist-pass@youtube.test/watch?v=entry",
            title: "Unsafe entry",
            duration: 30,
            thumbnailURL: nil
        )
        let playlist = PlaylistAnalysis(
            id: "playlist",
            title: "Unsafe playlist",
            entries: [entry]
        )
        let fixture = try StoreFixture(analysis: .playlist(playlist))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/playlist")
        await fixture.store.addPlaylistEntries(selectedIDs: [entry.id], options: .defaults)
        let addedJob = try XCTUnwrap(fixture.store.jobs.first)
        try await fixture.runner.waitForStart(of: addedJob.id)

        XCTAssertEqual(addedJob.sourceURL, "https://youtube.test/watch?v=entry")
        XCTAssertEqual(addedJob.sourceMetadata, "https://youtube.test/watch?v=entry")
        let startedSourceURLs = await fixture.runner.startedSourceURLs()
        XCTAssertEqual(startedSourceURLs[addedJob.id], "https://youtube.test/watch?v=entry")
    }

    func testOnlyQueuedJobCanBeEdited() async throws {
        let fixture = try StoreFixture(jobs: [.fixture(status: .queued), .fixture(status: .paused)])
        defer { fixture.cleanUp() }

        let queuedWasEdited = await fixture.store.editQueuedJob(
            fixture.store.jobs[0].id,
            options: .fixture(outputKind: .mp3)
        )
        let pausedWasEdited = await fixture.store.editQueuedJob(
            fixture.store.jobs[1].id,
            options: .fixture(outputKind: .mp3)
        )

        XCTAssertTrue(queuedWasEdited)
        XCTAssertFalse(pausedWasEdited)
        XCTAssertEqual(fixture.store.jobs[0].options.outputKind, .mp3)
        XCTAssertEqual(fixture.store.jobs[1].options.outputKind, .mp4)
    }

    func testQueuedJobEditorReanalyzesAllFormatsAndAppliesOnlyThatBatchItem() async throws {
        let first = DownloadJob.fixture(title: "First", status: .queued)
        let second = DownloadJob.fixture(title: "Second", status: .queued)
        let fresh = VideoAnalysis.fixture(
            sourceURL: first.sourceURL,
            videoFormats: [.fixture(id: "video-high"), .fixture(id: "video-low")],
            audioFormats: [.fixture(id: "audio-high"), .fixture(id: "audio-low")]
        )
        let fixture = try StoreFixture(jobs: [first, second], analysis: .video(fresh))
        defer { fixture.cleanUp() }

        let preparedSession = await fixture.store.prepareQueuedJobEdit(first.id)
        let session = try XCTUnwrap(preparedSession)
        XCTAssertEqual(session.analysis.videoFormats.map(\.id), ["video-high", "video-low"])
        XCTAssertEqual(session.analysis.audioFormats.map(\.id), ["audio-high", "audio-low"])

        var presentation = MediaOptionsPresentation(analysis: session.analysis, defaults: session.options)
        presentation.selectVideo("video-low")
        presentation.selectAudio("audio-low")
        let applied = await fixture.store.applyQueuedJobEdit(session, options: presentation.options)

        XCTAssertTrue(applied)
        XCTAssertEqual(fixture.store.jobs[0].options.videoQuality, .format(id: "video-low", label: "video-low"))
        XCTAssertEqual(fixture.store.jobs[0].options.audioQuality, .format(id: "audio-low", label: "audio-low"))
        XCTAssertEqual(fixture.store.jobs[1].options, second.options)
    }

    func testQueuedJobEditAnalysisCannotApplyAfterJobStarts() async throws {
        let job = DownloadJob.fixture(status: .queued)
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(jobs: [job], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        let preparation = Task { await fixture.store.prepareQueuedJobEdit(job.id) }
        try await analysis.waitForRequestCount(1)
        await fixture.store.start(job.id)
        try await fixture.runner.waitForStart(of: job.id)
        await analysis.succeed(request: 0, with: .video(.fixture(sourceURL: job.sourceURL)))

        let preparedEdit = await preparation.value
        XCTAssertNil(preparedEdit)
        await fixture.store.cancel(job.id)
    }

    func testRemoveCompletedRecordKeepsMediaFile() async throws {
        let completed = try StoreFixture.completedJobWithMedia()
        defer { completed.fixture.cleanUp() }

        await completed.fixture.store.removeRecord(completed.job.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.mediaURL.path))
        XCTAssertFalse(completed.fixture.store.jobs.contains(where: { $0.id == completed.job.id }))
    }

    func testRemoveFailedRecordReleasesOwnedArtifactsBeforeRemovingHistory() async throws {
        var failed = DownloadJob.fixture(status: .failed)
        failed.reservedOutputBasename = "Reserved title"
        let fixture = try StoreFixture(jobs: [failed])
        defer { fixture.cleanUp() }

        await fixture.store.removeRecord(failed.id)

        let cleanedJobIDs = await fixture.runner.cleanedJobIDs()
        XCTAssertEqual(cleanedJobIDs, [failed.id])
        XCTAssertTrue(fixture.store.jobs.isEmpty)
    }

    func testClearHistoryRemovesEveryTerminalRecordButKeepsDownloadWork() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("finished.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let completed = DownloadJob.fixture(status: .completed, outputURL: mediaURL)
        let failed = DownloadJob.fixture(status: .failed)
        let cancelled = DownloadJob.fixture(status: .cancelled)
        let queued = DownloadJob.fixture(status: .queued)
        let paused = DownloadJob.fixture(status: .paused)
        let fixture = try StoreFixture(jobs: [completed, failed, cancelled, queued, paused])
        defer { fixture.cleanUp() }
        let thumbnail = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        _ = try await fixture.thumbnailCache.store(data: thumbnail, for: completed.id)
        _ = try await fixture.thumbnailCache.store(data: thumbnail, for: failed.id)
        _ = try await fixture.thumbnailCache.store(data: thumbnail, for: queued.id)

        await fixture.store.clearHistory()

        let cleanedJobIDs = await fixture.runner.cleanedJobIDs()
        let completedThumbnail = await fixture.thumbnailCache.url(for: completed.id)
        let failedThumbnail = await fixture.thumbnailCache.url(for: failed.id)
        let queuedThumbnail = await fixture.thumbnailCache.url(for: queued.id)
        XCTAssertEqual(Set(fixture.store.jobs.map(\.id)), Set([queued.id, paused.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
        XCTAssertEqual(Set(cleanedJobIDs), Set([failed.id, cancelled.id]))
        XCTAssertNil(completedThumbnail)
        XCTAssertNil(failedThumbnail)
        XCTAssertNotNil(queuedThumbnail)
    }

    func testClearHistoryKeepsFailedRecordWhenOwnedArtifactsCannotBeReleased() async throws {
        let failed = DownloadJob.fixture(status: .failed)
        let completed = DownloadJob.fixture(status: .completed)
        let fixture = try StoreFixture(jobs: [failed, completed])
        defer { fixture.cleanUp() }
        await fixture.runner.failCleanup(for: failed.id)

        await fixture.store.clearHistory()

        XCTAssertEqual(fixture.store.jobs.map(\.id), [failed.id])
    }

    func testClearHistoryBlocksRetryWhileTerminalCleanupIsInFlight() async throws {
        var failed = DownloadJob.fixture(status: .failed)
        failed.reservedOutputBasename = "Reserved title"
        let analyzer = AnalysisRecorder(result: .video(.fixture()))
        let fixture = try StoreFixture(
            jobs: [failed],
            analysis: { url, options in try await analyzer.analyze(url: url, options: options) }
        )
        defer { fixture.cleanUp() }
        await fixture.runner.blockCleanup(for: failed.id)

        let clearing = Task { await fixture.store.clearHistory() }
        try await fixture.runner.waitForCleanup(of: failed.id)
        await fixture.store.retry(failed.id)

        let analyzedURLs = await analyzer.recordedURLs()
        XCTAssertEqual(analyzedURLs, [])
        await fixture.runner.releaseCleanup(for: failed.id)
        await clearing.value
        XCTAssertTrue(fixture.store.jobs.isEmpty)
    }

    func testRestoreConvertsInterruptedJobsToPausedWithoutStartingThem() async throws {
        let jobs: [DownloadJob] = [
            .fixture(status: .analyzing),
            .fixture(status: .downloading),
            .fixture(status: .merging),
            .fixture(status: .queued),
            .fixture(status: .completed)
        ]
        let fixture = try StoreFixture(jobs: jobs)
        defer { fixture.cleanUp() }

        XCTAssertEqual(fixture.store.jobs.map(\.status), [.paused, .paused, .paused, .queued, .completed])
        let startedIDs = await fixture.runner.startedIDs()
        XCTAssertEqual(startedIDs, [])
    }

    func testRestoreStripsUserInfoFromRetainedMediaURLsBeforePublishingHistory() async throws {
        var queued = DownloadJob.fixture(
            sourceURL: "https://stored-user:stored-pass@youtube.test/watch?v=queued",
            status: .queued
        )
        queued.sourceMetadata = "https://meta-user:meta-pass@youtube.test/watch?v=queued"
        var completed = DownloadJob.fixture(
            sourceURL: "https://done-user:done-pass@youtube.test/watch?v=done",
            status: .completed
        )
        completed.sourceMetadata = "https://done-meta:done-secret@youtube.test/watch?v=done"
        let fixture = try StoreFixture(jobs: [queued, completed])
        defer { fixture.cleanUp() }

        XCTAssertEqual(fixture.store.jobs[0].sourceURL, "https://youtube.test/watch?v=queued")
        XCTAssertEqual(fixture.store.jobs[0].sourceMetadata, "https://youtube.test/watch?v=queued")
        XCTAssertEqual(fixture.store.jobs[1].sourceURL, "https://youtube.test/watch?v=done")
        XCTAssertEqual(fixture.store.jobs[1].sourceMetadata, "https://youtube.test/watch?v=done")

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: queued.id)

        let startedSourceURLs = await fixture.runner.startedSourceURLs()
        XCTAssertEqual(startedSourceURLs[queued.id], "https://youtube.test/watch?v=queued")
    }

    func testCancellingRestoredPausedJobDelegatesRunnerOwnedCleanup() async throws {
        let restored = DownloadJob.fixture(status: .paused)
        let fixture = try StoreFixture(jobs: [restored])
        defer { fixture.cleanUp() }

        await fixture.store.cancel(restored.id)

        try await waitUntil("restored paused cancellation") {
            fixture.store.jobs.first?.status == .cancelled
        }
        let cleanedIDs = await fixture.runner.cancelledIDs()
        XCTAssertEqual(cleanedIDs, [restored.id])
    }

    func testRetryReanalyzesBeforeRequeueingWithOriginalOptions() async throws {
        let originalOptions = DownloadOptions.fixture(outputKind: .mp3)
        let failedJob = DownloadJob.fixture(status: .failed, outputKind: .mp3)
        let analysis = AnalysisRecorder(result: .video(.fixture(sourceURL: failedJob.sourceURL)))
        let fixture = try StoreFixture(jobs: [failedJob], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        await fixture.store.retry(failedJob.id)

        let requestedURLs = await analysis.recordedURLs()
        XCTAssertEqual(requestedURLs, [failedJob.sourceURL])
        XCTAssertEqual(fixture.store.jobs[0].status, .queued)
        XCTAssertEqual(fixture.store.jobs[0].retryCount, 1)
        XCTAssertEqual(fixture.store.jobs[0].options, originalOptions)
    }

    func testFailedJobCanRetryAndStartAgainInSameCoordinatorSession() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job], analysis: .video(.fixture(sourceURL: job.sourceURL)))
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStartCount(1, of: job.id)
        await fixture.runner.fail(
            DownloadFailure(category: .downloadFailed, technicalDetail: "first attempt failed"),
            for: job.id
        )
        try await waitUntil("job failure") {
            fixture.store.jobs.first?.status == .failed
        }

        await fixture.store.retry(job.id)
        XCTAssertEqual(fixture.store.jobs.first?.status, .queued)
        await fixture.store.start(job.id)

        try await fixture.runner.waitForStartCount(2, of: job.id)
        await fixture.store.cancel(job.id)
    }

    func testRetryRemovalAndReorderingCannotMutateSurvivingRecord() async throws {
        let failed = DownloadJob.fixture(title: "Retry target", status: .failed)
        let survivor = DownloadJob.fixture(title: "Completed survivor", status: .completed)
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(jobs: [failed, survivor], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        let retry = Task { await fixture.store.retry(failed.id) }
        try await analysis.waitForRequestCount(1)
        await fixture.store.removeRecord(failed.id)
        try await analysis.waitForCancellationCount(1)
        await analysis.succeed(request: 0, with: .video(.fixture(sourceURL: failed.sourceURL, title: "Refreshed target")))
        await retry.value

        XCTAssertEqual(fixture.store.jobs, [survivor])
    }

    func testRetryRemovalWithNoSurvivorDoesNotApplyStaleResult() async throws {
        let failed = DownloadJob.fixture(title: "Only record", status: .failed)
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(jobs: [failed], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        let retry = Task { await fixture.store.retry(failed.id) }
        try await analysis.waitForRequestCount(1)
        await fixture.store.removeRecord(failed.id)
        try await analysis.waitForCancellationCount(1)
        await analysis.succeed(request: 0, with: .video(.fixture(sourceURL: failed.sourceURL)))
        await retry.value

        XCTAssertTrue(fixture.store.jobs.isEmpty)
    }

    func testRepeatedRetryInvalidatesEarlierOperation() async throws {
        let failed = DownloadJob.fixture(title: "Original", status: .failed)
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(jobs: [failed], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        let first = Task { await fixture.store.retry(failed.id) }
        try await analysis.waitForRequestCount(1)
        let second = Task { await fixture.store.retry(failed.id) }
        try await analysis.waitForRequestCount(2)
        try await analysis.waitForCancellationCount(1)
        await analysis.succeed(request: 1, with: .video(.fixture(sourceURL: failed.sourceURL, title: "Newest")))
        await second.value
        await analysis.succeed(request: 0, with: .video(.fixture(sourceURL: failed.sourceURL, title: "Stale")))
        await first.value

        XCTAssertEqual(fixture.store.jobs.first?.title, "Newest")
        XCTAssertEqual(fixture.store.jobs.first?.retryCount, 1)
        XCTAssertEqual(fixture.store.jobs.first?.status, .queued)
    }

    func testRetryRequiresStoredVideoAndAudioFormatsToRemainAvailable() async throws {
        var failed = DownloadJob.fixture(status: .failed)
        failed.options = .fixture(
            videoQuality: .format(id: "video-137", label: "1080p"),
            audioQuality: .format(id: "audio-251", label: "Opus")
        )
        let refreshed = VideoAnalysis.fixture(
            sourceURL: failed.sourceURL,
            videoFormats: [.fixture(id: "video-136")],
            audioFormats: [.fixture(id: "audio-140")]
        )
        let fixture = try StoreFixture(jobs: [failed], analysis: .video(refreshed))
        defer { fixture.cleanUp() }

        await fixture.store.retry(failed.id)

        XCTAssertEqual(fixture.store.jobs.first?.status, .failed)
        XCTAssertEqual(fixture.store.jobs.first?.failure?.category, .formatReselectionRequired)
        XCTAssertEqual(fixture.store.jobs.first?.retryCount, 0)
    }

    func testFailedJobEditReanalyzesWithChangedOptionsAndReturnsOnlyFreshFormats() async throws {
        var failed = DownloadJob.fixture(status: .failed)
        failed.failure = DownloadFailure(category: .authenticationRequired)
        failed.options = DownloadOptions(
            videoQuality: .format(id: "stale-video", label: "Old video"),
            audioQuality: .format(id: "stale-audio", label: "Old audio")
        )
        let fresh = VideoAnalysis.fixture(
            sourceURL: failed.sourceURL,
            title: "Fresh metadata",
            videoFormats: [.fixture(id: "fresh-video")],
            audioFormats: [.fixture(id: "fresh-audio")]
        )
        let analysis = AnalysisRecorder(result: .video(fresh))
        let fixture = try StoreFixture(jobs: [failed], analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }
        var changedOptions = failed.options
        changedOptions.cookies = .safari
        changedOptions.outputDirectoryBookmark = Data("new-folder".utf8)
        changedOptions.outputDirectoryDisplayPath = "/tmp/New Folder"

        let session = await fixture.store.prepareFailedJobEdit(failed.id, options: changedOptions)

        let prepared = try XCTUnwrap(session)
        let recordedOptions = await analysis.recordedOptions()
        XCTAssertEqual(recordedOptions.map(\.cookies), [.safari])
        XCTAssertEqual(prepared.analysis, fresh)
        XCTAssertEqual(prepared.options.cookies, .safari)
        XCTAssertEqual(prepared.options.outputDirectoryDisplayPath, "/tmp/New Folder")
        XCTAssertEqual(prepared.options.videoQuality, .format(id: "fresh-video", label: "fresh-video"))
        XCTAssertEqual(prepared.options.audioQuality, .format(id: "fresh-audio", label: "fresh-audio"))
        XCTAssertEqual(fixture.store.jobs.first?.status, .failed)
        XCTAssertEqual(fixture.store.jobs.first?.options.videoQuality, .format(id: "stale-video", label: "Old video"))
    }

    func testApplyingFreshFailedJobEditSessionUpdatesSameRecordAndQueuesRetry() async throws {
        var failed = DownloadJob.fixture(title: "Old metadata", status: .failed)
        failed.failure = DownloadFailure(category: .formatReselectionRequired)
        let fresh = VideoAnalysis.fixture(
            sourceURL: failed.sourceURL,
            title: "Fresh metadata",
            videoFormats: [.fixture(id: "fresh-video")],
            audioFormats: [.fixture(id: "fresh-audio")]
        )
        let fixture = try StoreFixture(jobs: [failed], analysis: .video(fresh))
        defer { fixture.cleanUp() }
        let preparedSession = await fixture.store.prepareFailedJobEdit(failed.id, options: failed.options)
        let session = try XCTUnwrap(preparedSession)

        let applied = await fixture.store.applyFailedJobEdit(session, options: session.options)

        let retained = try XCTUnwrap(fixture.store.jobs.first)
        XCTAssertTrue(applied)
        XCTAssertEqual(retained.id, failed.id)
        XCTAssertEqual(retained.title, "Fresh metadata")
        XCTAssertEqual(retained.status, .queued)
        XCTAssertNil(retained.failure)
        XCTAssertEqual(retained.retryCount, 1)
        XCTAssertEqual(retained.options, session.options)
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first, retained)
    }

    func testApplyingFailedJobEditSessionScrubsRetainedMediaURLsBeforeRetry() async throws {
        var failed = DownloadJob.fixture(title: "Old metadata", status: .failed)
        failed.failure = DownloadFailure(category: .formatReselectionRequired)
        let safe = VideoAnalysis.fixture(
            sourceURL: failed.sourceURL,
            videoFormats: [.fixture(id: "fresh-video")],
            audioFormats: [.fixture(id: "fresh-audio")]
        )
        let fixture = try StoreFixture(jobs: [failed], analysis: .video(safe))
        defer { fixture.cleanUp() }
        let preparedSession = await fixture.store.prepareFailedJobEdit(failed.id, options: failed.options)
        let session = try XCTUnwrap(preparedSession)
        let unsafeAnalysis = VideoAnalysis.fixture(
            sourceURL: "https://edit-user:edit-pass@youtube.test/watch?v=retry",
            title: "Fresh metadata",
            thumbnailURL: URL(string: "https://thumb-user:thumb-pass@images.test/retry.jpg"),
            videoFormats: [.fixture(id: "fresh-video")],
            audioFormats: [.fixture(id: "fresh-audio")]
        )
        let unsafeSession = FailedJobEditSession(
            jobID: session.jobID,
            generation: session.generation,
            analysis: unsafeAnalysis,
            options: session.options
        )

        let applied = await fixture.store.applyFailedJobEdit(unsafeSession, options: unsafeSession.options)

        let retained = try XCTUnwrap(fixture.store.jobs.first)
        XCTAssertTrue(applied)
        XCTAssertEqual(retained.sourceURL, "https://youtube.test/watch?v=retry")
        XCTAssertEqual(retained.sourceMetadata, "https://youtube.test/watch?v=retry")
        XCTAssertNil(retained.thumbnailCachePath)
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first?.sourceURL, "https://youtube.test/watch?v=retry")
        await fixture.store.start(failed.id)
        try await fixture.runner.waitForStart(of: failed.id)
        let startedSourceURLs = await fixture.runner.startedSourceURLs()
        XCTAssertEqual(startedSourceURLs[failed.id], "https://youtube.test/watch?v=retry")
    }

    func testFailedJobEditRejectsFormatOutsideFreshSession() async throws {
        var failed = DownloadJob.fixture(status: .failed)
        failed.failure = DownloadFailure(category: .formatReselectionRequired)
        let fresh = VideoAnalysis.fixture(
            sourceURL: failed.sourceURL,
            videoFormats: [.fixture(id: "fresh-video")],
            audioFormats: [.fixture(id: "fresh-audio")]
        )
        let fixture = try StoreFixture(jobs: [failed], analysis: .video(fresh))
        defer { fixture.cleanUp() }
        let preparedSession = await fixture.store.prepareFailedJobEdit(failed.id, options: failed.options)
        let session = try XCTUnwrap(preparedSession)
        var staleOptions = session.options
        staleOptions.videoQuality = .format(id: "stale-video", label: "Stale")

        let applied = await fixture.store.applyFailedJobEdit(session, options: staleOptions)

        XCTAssertFalse(applied)
        XCTAssertEqual(fixture.store.jobs.first?.status, .failed)
        XCTAssertEqual(fixture.store.jobs.first?.failure?.category, .formatReselectionRequired)
        XCTAssertEqual(fixture.store.jobs.first?.retryCount, 0)
    }

    func testNewestAnalysisResultWinsWhenEarlierRequestFinishesLast() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }

        let first = Task { await fixture.store.analyzeURL("https://youtube.test/old") }
        try await analysis.waitForRequestCount(1)
        let second = Task { await fixture.store.analyzeURL("https://youtube.test/new") }
        await analysis.succeed(request: 0, with: .video(.fixture(sourceURL: "https://youtube.test/old", title: "Old")))
        await first.value
        try await analysis.waitForRequestCount(2)
        XCTAssertEqual(fixture.store.analysisState, .analyzing)
        await analysis.succeed(request: 1, with: .video(.fixture(sourceURL: "https://youtube.test/new", title: "New")))
        await second.value

        guard case let .video(video) = fixture.store.analysisState else {
            return XCTFail("Expected latest video analysis")
        }
        XCTAssertEqual(video.title, "New")
    }

    func testQueueChangesPersistImmediately() async throws {
        let fixture = try StoreFixture(analysis: .video(.fixture()))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/video")
        await fixture.store.addVideo(options: .defaults)

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.queued])
    }

    func testSynthesizedTitleSourceCarriesFromAnalysisIntoPersistedJobs() async throws {
        let analysis = VideoAnalysis.fixture(
            title: "Untitled video",
            titleSource: .synthesizedUntitledVideo
        )
        let fixture = try StoreFixture(analysis: .video(analysis))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL(analysis.sourceURL)
        await fixture.store.addVideo(options: .defaults)

        XCTAssertEqual(fixture.store.jobs.first?.titleSource, .synthesizedUntitledVideo)
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first?.titleSource, .synthesizedUntitledVideo)
    }

    func testSynthesizedPlaylistEntryTitleSourceCarriesIntoPersistedJob() async throws {
        let entry = PlaylistEntry(
            id: "entry",
            sourceURL: "https://youtube.test/watch?v=entry",
            title: "Unavailable video",
            titleSource: .synthesizedUnavailableVideo,
            duration: nil,
            thumbnailURL: nil
        )
        let playlist = PlaylistAnalysis(
            id: "playlist",
            title: "Untitled playlist",
            titleSource: .synthesizedUntitledPlaylist,
            entries: [entry]
        )
        let fixture = try StoreFixture(analysis: .playlist(playlist))
        defer { fixture.cleanUp() }

        await fixture.store.analyzeURL("https://youtube.test/playlist")
        await fixture.store.addPlaylistEntries(selectedIDs: [entry.id], options: .defaults)

        XCTAssertEqual(fixture.store.jobs.first?.titleSource, .synthesizedUnavailableVideo)
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first?.titleSource, .synthesizedUnavailableVideo)
    }

    func testCoordinatorStartedImmediatelyTransitionsAndPersistsAnalyzing() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        try await waitUntil("store to apply coordinator start") {
            fixture.store.jobs.first?.status == .analyzing
        }

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first?.status, .paused)
        XCTAssertNotNil(fixture.store.jobs.first?.startedAt)
    }

    func testCoordinatorPreservesTypedSanitizedFailure() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }
        let failure = DownloadFailure(
            category: .diskFull,
            technicalDetail: "token=secret disk is full",
            toolExitCode: 28
        )

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.runner.fail(failure, for: job.id)
        try await waitUntil("store to receive typed failure") {
            fixture.store.jobs.first?.status == .failed
        }

        let expected = DownloadFailure(
            category: .diskFull,
            technicalDetail: "token=[REDACTED] disk is full",
            toolExitCode: 28,
            occurredAt: failure.occurredAt
        )
        XCTAssertEqual(fixture.store.jobs.first?.failure, expected)
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first?.failure, expected)
    }

    func testUserPauseDoesNotInterruptVisibleMergingJob() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.runner.emit(.phase(.merging), for: job.id)
        try await waitUntil("store to receive merge phase") {
            fixture.store.jobs.first?.status == .merging
        }

        await fixture.store.pause(job.id)
        await fixture.store.pauseAll()

        let quitInterruptedIDs = await fixture.runner.quitInterruptedIDs()
        XCTAssertEqual(quitInterruptedIDs, [])
        XCTAssertEqual(fixture.store.jobs.first?.status, .merging)
    }

    func testIndividualResumeRestartsManagedPausedJobExactlyOnce() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStartCount(1, of: job.id)
        await fixture.store.pause(job.id)
        try await waitUntil("managed job to become paused") {
            fixture.store.jobs.first?.status == .paused
        }

        async let first: Void = fixture.store.resume(job.id)
        async let second: Void = fixture.store.resume(job.id)
        await first
        await second

        try await fixture.runner.waitForStartCount(2, of: job.id)
        let starts = await fixture.runner.startedIDs()
        XCTAssertEqual(starts.filter { $0 == job.id }.count, 2)
    }

    func testIndividualResumeEnqueuesRestoredPausedJob() async throws {
        let job = DownloadJob.fixture(status: .paused)
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.resume(job.id)

        try await fixture.runner.waitForStartCount(1, of: job.id)
        let starts = await fixture.runner.startedIDs()
        XCTAssertEqual(starts, [job.id])
    }

    func testResumeAllRestartsManagedPausedJobsExactlyOnce() async throws {
        let jobs = DownloadJob.fixtures(count: 2)
        let fixture = try StoreFixture(jobs: jobs, coordinatorLimit: 2)
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        for job in jobs {
            try await fixture.runner.waitForStartCount(1, of: job.id)
        }
        await fixture.store.pauseAll()
        try await waitUntil("managed jobs to become paused") {
            fixture.store.jobs.allSatisfy { $0.status == .paused }
        }

        async let first: Void = fixture.store.resumeAll()
        async let second: Void = fixture.store.resumeAll()
        await first
        await second

        for job in jobs {
            try await fixture.runner.waitForStartCount(2, of: job.id)
        }
        let starts = await fixture.runner.startedIDs()
        XCTAssertEqual(starts.count, 4)
        XCTAssertTrue(jobs.allSatisfy { job in starts.filter { $0 == job.id }.count == 2 })
    }

    func testResumeAllEnqueuesRestoredPausedJobs() async throws {
        let jobs = DownloadJob.fixtures(count: 2).map { job -> DownloadJob in
            var paused = job
            paused.status = .paused
            return paused
        }
        let fixture = try StoreFixture(jobs: jobs, coordinatorLimit: 2)
        defer { fixture.cleanUp() }

        await fixture.store.resumeAll()

        for job in jobs {
            try await fixture.runner.waitForStartCount(1, of: job.id)
        }
        let starts = await fixture.runner.startedIDs()
        XCTAssertEqual(Set(starts), Set(jobs.map(\.id)))
    }

    func testPrepareToQuitPersistsPausedActiveJobAfterCoordinatorShutdown() async throws {
        let activeJob = DownloadJob.fixture(status: .downloading)
        let fixture = try StoreFixture(jobs: [activeJob])
        defer { fixture.cleanUp() }

        try await fixture.store.prepareToQuit()

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.paused])
    }

    func testPrepareToQuitWaitsForRunningJobToBePersistedAsPaused() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.runner.emit(.phase(.downloading), for: job.id)
        try await waitUntil("store to receive the downloading phase") {
            fixture.store.jobs.first?.status == .downloading
        }

        try await fixture.store.prepareToQuit()

        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.map(\.status), [.paused])
    }

    func testPrepareToQuitConvertsMergingJobToRestartablePausedState() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.runner.emit(.phase(.merging), for: job.id)
        try await waitUntil("store to receive the merging phase") {
            fixture.store.jobs.first?.status == .merging
        }

        try await fixture.store.prepareToQuit()

        XCTAssertEqual(fixture.store.jobs.map(\.status), [.paused])
    }

    func testConcurrentQuitCallersJoinOneShutdownOperation() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }
        await fixture.runner.blockQuit()
        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)

        let firstCompletion = CompletionProbe()
        let secondCompletion = CompletionProbe()
        let first = Task {
            try await fixture.store.prepareToQuit()
            await firstCompletion.complete()
        }
        try await fixture.runner.waitForQuitRequest()
        let second = Task {
            try await fixture.store.prepareToQuit()
            await secondCompletion.complete()
        }
        try await Task.sleep(for: .milliseconds(20))

        let firstCompletedEarly = await firstCompletion.value()
        let secondCompletedEarly = await secondCompletion.value()
        XCTAssertFalse(firstCompletedEarly)
        XCTAssertFalse(secondCompletedEarly)
        await fixture.runner.releaseQuit()
        try await first.value
        try await second.value
        let firstCompleted = await firstCompletion.value()
        let secondCompleted = await secondCompletion.value()
        XCTAssertTrue(firstCompleted)
        XCTAssertTrue(secondCompleted)
    }

    func testQuitDrainsBufferedEventsBeforeFinalFlush() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }
        let output = fixture.root.appendingPathComponent("finished.mp4")
        await fixture.runner.setQuitEvents([
            .reservedBasename("must-survive"),
            .phase(.merging),
            .progress(JobProgress(
                fraction: 0.95,
                downloadedBytes: 95,
                totalBytes: 100,
                bytesPerSecond: 10,
                etaSeconds: 1
            )),
            .output(output)
        ])
        await fixture.runner.blockQuitAfterEvents()
        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)

        let quit = Task { try await fixture.store.prepareToQuit() }
        try await fixture.runner.waitForQuitEvents()
        try await waitUntil("store to drain the shutdown phase") {
            fixture.store.jobs.first?.status == .merging
                && fixture.store.jobs.first?.reservedOutputBasename == "must-survive"
                && fixture.store.jobs.first?.outputURL == output
                && fixture.store.jobs.first?.progress == 0.95
        }
        await fixture.runner.releaseQuitAfterEvents()
        try await quit.value

        let retained = try XCTUnwrap(fixture.store.jobs.first)
        XCTAssertEqual(retained.status, .paused)
        XCTAssertEqual(retained.reservedOutputBasename, "must-survive")
        XCTAssertEqual(retained.outputURL, output)
        XCTAssertEqual(retained.progress, 0.95)
        XCTAssertEqual(retained.downloadedBytes, 95)
        let persisted = try await fixture.persistence.loadJobs()
        XCTAssertEqual(persisted.first?.reservedOutputBasename, "must-survive")
        XCTAssertEqual(persisted.first?.outputURL, output)
        XCTAssertEqual(persisted.first?.progress, 0.95)
    }

    func testQuitCancelsAndJoinsActiveAnalysisWithoutApplyingItsResult() async throws {
        let analysis = ControlledAnalysis()
        let fixture = try StoreFixture(analysis: { url, options in
            try await analysis.analyze(url: url, options: options)
        })
        defer { fixture.cleanUp() }
        let analysisTask = Task { await fixture.store.analyzeURL("https://youtube.test/video") }
        try await analysis.waitForRequestCount(1)
        let quitCompletion = CompletionProbe()
        let quit = Task {
            try await fixture.store.prepareToQuit()
            await quitCompletion.complete()
        }

        try await analysis.waitForCancellationCount(1)
        try await Task.sleep(for: .milliseconds(20))
        let quitCompletedEarly = await quitCompletion.value()
        XCTAssertFalse(quitCompletedEarly)
        await analysis.succeed(request: 0, with: .video(.fixture(title: "Too late")))
        try await quit.value
        await analysisTask.value
        XCTAssertNotEqual(fixture.store.analysisState, .video(.fixture(title: "Too late")))
    }

    func testQuitFinalFlushFailureIsThrown() async throws {
        let parent = try temporaryDirectory()
        let blockedRoot = parent.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedRoot)
        let fixture = try StoreFixture(root: blockedRoot)
        defer { try? FileManager.default.removeItem(at: parent) }

        do {
            try await fixture.store.prepareToQuit()
            XCTFail("Expected final persistence flush to fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testTerminationSafetyPolicyApprovesOnlySuccessfulPreparation() {
        XCTAssertTrue(TerminationSafetyPolicy.shouldTerminate(after: .success(())))
        XCTAssertFalse(TerminationSafetyPolicy.shouldTerminate(after: .failure(StoreTestWaitError.timedOut("flush"))))
    }

    func testAppLifecycleOwnsStoreSynchronously() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }

        let lifecycle = AppLifecycle(store: fixture.store)

        XCTAssertTrue(lifecycle.store === fixture.store)
        try await fixture.store.prepareToQuit()
    }

    func testAppLifecycleLaunchOwnsBothStoresAndStartsMockRestoration() async throws {
        let updater = StoreUpdateChecker(result: .upToDate)
        let fixture = try StoreFixture(updateChecker: updater)
        defer { fixture.cleanUp() }
        let envelope = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "restore")
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            restoreResult: .success(.fixture(provider: .google))
        )
        let accountStore = AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([provider])
        )
        let lifecycle = AppLifecycle(store: fixture.store, accountSessionStore: accountStore)

        let application = NSApplication.shared
        lifecycle.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: application)
        )
        try await waitUntil("mock session restoration") {
            if case .signedIn = accountStore.state { return true }
            return false
        }
        try await updater.waitForCallCount(1)

        XCTAssertTrue(lifecycle.store === fixture.store)
        XCTAssertTrue(lifecycle.accountSessionStore === accountStore)
        let updateCalls = await updater.manualArguments()
        XCTAssertEqual(updateCalls, [false])
    }

    func testQuitStopsRecordMutations() async throws {
        let active = DownloadJob.fixture()
        let completed = DownloadJob.fixture(status: .completed)
        let fixture = try StoreFixture(jobs: [active, completed])
        defer { fixture.cleanUp() }
        await fixture.runner.blockQuit()
        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: active.id)
        let quit = Task { try await fixture.store.prepareToQuit() }
        try await fixture.runner.waitForQuitRequest()

        await fixture.store.removeRecord(completed.id)

        XCTAssertTrue(fixture.store.jobs.contains(where: { $0.id == completed.id }))
        await fixture.runner.releaseQuit()
        try await quit.value
    }

    func testRemovalJoinsThumbnailWorkAndCannotRecreateCache() async throws {
        let loader = ControlledThumbnailLoader()
        let fixture = try StoreFixture(
            analysis: .video(.fixture(thumbnailURL: URL(string: "https://images.test/thumb.png"))),
            thumbnailLoader: ThumbnailDataLoader { url in try await loader.load(url) }
        )
        defer { fixture.cleanUp() }
        await fixture.store.analyzeURL("https://youtube.test/video")
        await fixture.store.addVideo(options: .defaults)
        let jobID = try XCTUnwrap(fixture.store.jobs.first?.id)
        try await loader.waitForRequest()
        await fixture.store.cancel(jobID)
        try await waitUntil("auto-started job cancellation") {
            fixture.store.jobs.first(where: { $0.id == jobID })?.status == .cancelled
        }
        let removalCompletion = CompletionProbe()
        let removal = Task {
            await fixture.store.removeRecord(jobID)
            await removalCompletion.complete()
        }

        try await loader.waitForCancellation()
        try await Task.sleep(for: .milliseconds(20))
        let removalCompletedEarly = await removalCompletion.value()
        XCTAssertFalse(removalCompletedEarly)
        await loader.release()
        await removal.value
        try await loader.waitForCompletion()
        let cachedURL = await fixture.thumbnailCache.url(for: jobID)
        XCTAssertNil(cachedURL)
    }

    func testQuitJoinsThumbnailWorkBeforeReturning() async throws {
        let loader = ControlledThumbnailLoader()
        let fixture = try StoreFixture(
            analysis: .video(.fixture(thumbnailURL: URL(string: "https://images.test/thumb.png"))),
            thumbnailLoader: ThumbnailDataLoader { url in try await loader.load(url) }
        )
        defer { fixture.cleanUp() }
        await fixture.store.analyzeURL("https://youtube.test/video")
        await fixture.store.addVideo(options: .defaults)
        try await loader.waitForRequest()
        let quitCompletion = CompletionProbe()
        let quit = Task {
            try await fixture.store.prepareToQuit()
            await quitCompletion.complete()
        }

        try await loader.waitForCancellation()
        try await Task.sleep(for: .milliseconds(20))
        let quitCompletedEarly = await quitCompletion.value()
        XCTAssertFalse(quitCompletedEarly)
        await loader.release()
        try await quit.value
        try await loader.waitForCompletion()
        let quitCompleted = await quitCompletion.value()
        XCTAssertTrue(quitCompleted)
    }

    func testDeinitCancelsThumbnailWorkWithoutRecreatingCache() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = ControlledThumbnailLoader()
        let runner = StoreRunner()
        let coordinator = DownloadCoordinator(limit: 1, runner: runner)
        let thumbnailCache = ThumbnailCache(
            root: root,
            loader: ThumbnailDataLoader { url in try await loader.load(url) }
        )
        var store: DownloadStore? = DownloadStore(
            coordinator: coordinator,
            persistence: PersistenceController(root: root),
            thumbnailCache: thumbnailCache,
            diagnostics: DiagnosticsLogger(root: root),
            metadataAnalyzer: ClosureMetadataAnalyzer { _, _ in
                .video(.fixture(thumbnailURL: URL(string: "https://images.test/thumb.png")))
            }
        )
        await store?.analyzeURL("https://youtube.test/video")
        await store?.addVideo(options: .defaults)
        let jobID = try XCTUnwrap(store?.jobs.first?.id)
        try await loader.waitForRequest()
        let weakStore = WeakStoreReference(store)

        store = nil

        try await waitUntil("store deinitialization") { weakStore.value == nil }
        try await loader.waitForCancellation()
        await loader.release()
        try await loader.waitForCompletion()
        let cachedURL = await thumbnailCache.url(for: jobID)
        XCTAssertNil(cachedURL)
        await coordinator.shutdown()
    }

    func testCancelStopsJobAlreadyStartedBeforeItsFirstPhaseEvent() async throws {
        let job = DownloadJob.fixture()
        let fixture = try StoreFixture(jobs: [job])
        defer { fixture.cleanUp() }

        await fixture.store.startAll()
        try await fixture.runner.waitForStart(of: job.id)
        await fixture.store.cancel(job.id)

        let cancelledIDs = await fixture.runner.cancelledIDs()
        XCTAssertEqual(cancelledIDs, [job.id])
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class StoreFixture {
    let root: URL
    let runner: StoreRunner
    let coordinator: DownloadCoordinator
    let persistence: PersistenceController
    let thumbnailCache: ThumbnailCache
    let store: DownloadStore

    convenience init(
        jobs: [DownloadJob] = [],
        analysis: AnalysisResult = .video(.fixture()),
        thumbnailLoader: ThumbnailDataLoader = .live,
        coordinatorLimit: Int = 1,
        bookmarks: OutputDirectoryBookmarkService = .live,
        settings: AppSettings = .defaults,
        settingsStore: AppSettingsStore = AppSettingsStore(),
        updateChecker: any UpdateChecking = StoreUpdateChecker(result: .upToDate),
        toolchainValidator: (any ToolchainHealthValidating)? = nil
    ) throws {
        try self.init(
            root: temporaryDirectory(),
            jobs: jobs,
            analysis: { _, _ in analysis },
            thumbnailLoader: thumbnailLoader,
            coordinatorLimit: coordinatorLimit,
            bookmarks: bookmarks,
            settings: settings,
            settingsStore: settingsStore,
            updateChecker: updateChecker,
            toolchainValidator: toolchainValidator
        )
    }

    convenience init(
        jobs: [DownloadJob] = [],
        analysis: @escaping @Sendable (String, DownloadOptions) async throws -> AnalysisResult,
        coordinatorLimit: Int = 1,
        toolchainValidator: (any ToolchainHealthValidating)? = nil
    ) throws {
        try self.init(
            root: temporaryDirectory(),
            jobs: jobs,
            analysis: analysis,
            coordinatorLimit: coordinatorLimit,
            toolchainValidator: toolchainValidator
        )
    }

    convenience init(root: URL, jobs: [DownloadJob] = []) throws {
        try self.init(root: root, jobs: jobs, analysis: { _, _ in .video(.fixture()) })
    }

    private init(
        root: URL,
        jobs: [DownloadJob],
        analysis: @escaping @Sendable (String, DownloadOptions) async throws -> AnalysisResult,
        thumbnailLoader: ThumbnailDataLoader = .live,
        coordinatorLimit: Int = 1,
        bookmarks: OutputDirectoryBookmarkService = .live,
        settings: AppSettings = .defaults,
        settingsStore: AppSettingsStore = AppSettingsStore(),
        updateChecker: any UpdateChecking = StoreUpdateChecker(result: .upToDate),
        toolchainValidator: (any ToolchainHealthValidating)? = nil
    ) throws {
        self.root = root
        runner = StoreRunner()
        coordinator = DownloadCoordinator(limit: coordinatorLimit, runner: runner)
        persistence = PersistenceController(root: root)
        thumbnailCache = ThumbnailCache(root: root, loader: thumbnailLoader)
        store = DownloadStore(
            jobs: jobs,
            settings: settings,
            coordinator: coordinator,
            persistence: persistence,
            thumbnailCache: thumbnailCache,
            diagnostics: DiagnosticsLogger(root: root),
            settingsStore: settingsStore,
            outputDirectoryBookmarks: bookmarks,
            metadataAnalyzer: ClosureMetadataAnalyzer(analysis),
            updateChecker: updateChecker,
            toolchainValidator: toolchainValidator
        )
    }

    static func completedJobWithMedia() throws -> (fixture: StoreFixture, job: DownloadJob, mediaURL: URL) {
        let directory = try temporaryDirectory()
        let mediaURL = directory.appendingPathComponent("finished.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let job = DownloadJob.fixture(status: .completed, outputURL: mediaURL)
        let fixture = try StoreFixture(jobs: [job])
        return (fixture, job, mediaURL)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum BookmarkFixtureError: Error {
    case creationFailed
    case unexpectedURL
}

private extension MacOSUpdateManifest {
    static func fixture() -> MacOSUpdateManifest {
        MacOSUpdateManifest(
            schemaVersion: 1,
            platform: "macos",
            latestVersion: "2.0.1",
            minimumMacOS: "13.0.0",
            releaseURL: URL(string: "https://example.invalid/releases/macos-example")!,
            downloadURL: URL(string: "https://example.invalid/macos-example.zip")!,
            sha256: String(repeating: "0", count: 64),
            publishedAt: "2026-08-18T00:00:00Z",
            releaseNotes: "Example only; not a release."
        )
    }
}

private actor StoreUpdateChecker: UpdateChecking {
    private let result: UpdateResult
    private var calls: [Bool] = []

    init(result: UpdateResult) {
        self.result = result
    }

    func check(manual: Bool) async -> UpdateResult {
        calls.append(manual)
        return result
    }

    func manualArguments() -> [Bool] {
        calls
    }

    func waitForCallCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while calls.count < count {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("update checker call")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor ControlledUpdateChecker: UpdateChecking {
    private var calls: [Bool] = []
    private var continuations: [Int: CheckedContinuation<UpdateResult, Never>] = [:]

    func check(manual: Bool) async -> UpdateResult {
        let index = calls.count
        calls.append(manual)
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func manualArguments() -> [Bool] {
        calls
    }

    func resolveCall(at index: Int, with result: UpdateResult) {
        continuations.removeValue(forKey: index)?.resume(returning: result)
    }

    func waitForCallCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while calls.count < count {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("controlled update checker call")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor StoreRunner: JobRunning {
    private var starts: [UUID] = []
    private var startURLs: [UUID: String] = [:]
    private var cancellations: [UUID] = []
    private var quitInterruptions: [UUID] = []
    private var continuations: [UUID: AsyncThrowingStream<DownloadEvent, Error>.Continuation] = [:]
    private var quitEvents: [DownloadEvent] = []
    private var quitIsBlocked = false
    private var quitRequestCount = 0
    private var quitWaiters: [CheckedContinuation<Void, Never>] = []
    private var quitAfterEventsIsBlocked = false
    private var didEmitQuitEvents = false
    private var quitAfterEventsWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanedJobs: [UUID] = []
    private var cleanupFailures: Set<UUID> = []
    private var blockedCleanupIDs: Set<UUID> = []
    private var cleanupWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated func events(for job: DownloadJob) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.recordStart(job, continuation: continuation) }
        }
    }

    func startedIDs() -> [UUID] { starts }
    func startedSourceURLs() -> [UUID: String] { startURLs }

    func pause(jobID: UUID) async -> Bool {
        guard continuations[jobID] != nil else { return false }
        finish(jobID)
        return true
    }
    func cancel(jobID: UUID) async {
        cancellations.append(jobID)
        finish(jobID)
    }
    func cleanupCancelledJob(_ job: DownloadJob) async -> Bool {
        cancellations.append(job.id)
        cleanedJobs.append(job.id)
        if blockedCleanupIDs.contains(job.id) {
            await withCheckedContinuation { continuation in
                cleanupWaiters[job.id, default: []].append(continuation)
            }
        }
        return !cleanupFailures.contains(job.id)
    }
    func interruptForQuit(jobID: UUID) async {
        quitInterruptions.append(jobID)
        quitRequestCount += 1
        if quitIsBlocked {
            await withCheckedContinuation { continuation in
                quitWaiters.append(continuation)
            }
        }
        for event in quitEvents {
            continuations[jobID]?.yield(event)
        }
        didEmitQuitEvents = true
        if quitAfterEventsIsBlocked {
            await withCheckedContinuation { continuation in
                quitAfterEventsWaiters.append(continuation)
            }
        }
        finish(jobID)
    }

    func emit(_ event: DownloadEvent, for jobID: UUID) {
        continuations[jobID]?.yield(event)
    }

    func waitForStart(of jobID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !starts.contains(jobID) {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("runner to start \(jobID)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitForStartCount(_ count: Int, of jobID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while starts.filter({ $0 == jobID }).count < count {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("runner to start \(jobID) \(count) times")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func cancelledIDs() -> [UUID] { cancellations }
    func cleanedJobIDs() -> [UUID] { cleanedJobs }
    func failCleanup(for jobID: UUID) { cleanupFailures.insert(jobID) }
    func blockCleanup(for jobID: UUID) { blockedCleanupIDs.insert(jobID) }
    func releaseCleanup(for jobID: UUID) {
        blockedCleanupIDs.remove(jobID)
        let waiters = cleanupWaiters.removeValue(forKey: jobID) ?? []
        waiters.forEach { $0.resume() }
    }
    func waitForCleanup(of jobID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !cleanedJobs.contains(jobID) {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("cleanup request for \(jobID)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func quitInterruptedIDs() -> [UUID] { quitInterruptions }

    func fail(_ failure: DownloadFailure, for jobID: UUID) {
        continuations.removeValue(forKey: jobID)?.finish(throwing: failure)
    }

    func setQuitEvents(_ events: [DownloadEvent]) {
        quitEvents = events
    }

    func blockQuit() {
        quitIsBlocked = true
    }

    func blockQuitAfterEvents() {
        quitAfterEventsIsBlocked = true
    }

    func releaseQuit() {
        quitIsBlocked = false
        let waiters = quitWaiters
        quitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func releaseQuitAfterEvents() {
        quitAfterEventsIsBlocked = false
        let waiters = quitAfterEventsWaiters
        quitAfterEventsWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForQuitRequest() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while quitRequestCount == 0 {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("runner quit request")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitForQuitEvents() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !didEmitQuitEvents {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("runner quit events")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func recordStart(
        _ job: DownloadJob,
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    ) {
        let jobID = job.id
        starts.append(jobID)
        startURLs[jobID] = job.sourceURL
        continuations[jobID] = continuation
    }

    private func finish(_ jobID: UUID) {
        continuations.removeValue(forKey: jobID)?.finish()
    }
}

private actor AnalysisRecorder {
    private let result: AnalysisResult
    private var requestedURLs: [String] = []
    private var requestedOptions: [DownloadOptions] = []

    init(result: AnalysisResult) {
        self.result = result
    }

    func analyze(url: String, options: DownloadOptions) async throws -> AnalysisResult {
        requestedURLs.append(url)
        requestedOptions.append(options)
        return result
    }

    func recordedURLs() -> [String] { requestedURLs }
    func recordedOptions() -> [DownloadOptions] { requestedOptions }
}

private actor StoreToolchainGate: ToolchainHealthValidating {
    private var results: [Result<ToolchainHealth, DownloadFailure>]
    private var arguments: [Bool] = []

    init(results: [Result<ToolchainHealth, DownloadFailure>]) {
        self.results = results
    }

    func validate(force: Bool) async throws -> ToolchainHealth {
        arguments.append(force)
        guard !results.isEmpty else { return .fixture }
        return try results.removeFirst().get()
    }

    func forcedArguments() -> [Bool] { arguments }
}

private struct ClosureMetadataAnalyzer: MetadataAnalyzing {
    let handler: @Sendable (String, DownloadOptions) async throws -> AnalysisResult

    init(_ handler: @escaping @Sendable (String, DownloadOptions) async throws -> AnalysisResult) {
        self.handler = handler
    }

    func analyze(url: String, options: DownloadOptions) async throws -> AnalysisResult {
        try await handler(url, options)
    }
}

private actor ControlledAnalysis {
    private struct Request {
        let url: String
        let continuation: CheckedContinuation<AnalysisResult, Error>
    }

    private var requests: [Request] = []
    private var cancellationCount = 0

    func analyze(url: String, options: DownloadOptions) async throws -> AnalysisResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(url: url, continuation: continuation))
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    func succeed(request index: Int, with result: AnalysisResult) {
        requests[index].continuation.resume(returning: result)
    }

    func fail(request index: Int, with error: DownloadFailure) {
        requests[index].continuation.resume(throwing: error)
    }

    func recordedURLs() -> [String] {
        requests.map(\.url)
    }

    func waitForRequestCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while requests.count < count {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("analysis request count \(count)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitForCancellationCount(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while cancellationCount < count {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut("analysis cancellation count \(count)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func recordCancellation() {
        cancellationCount += 1
    }
}

private actor ControlledThumbnailLoader {
    private var requestCount = 0
    private var completionCount = 0
    private var cancellationCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func load(_ url: URL) async throws -> ThumbnailDownload {
        requestCount += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        completionCount += 1
        return ThumbnailDownload(data: storePNGData, mimeType: "image/png")
    }

    func release() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func waitForRequest() async throws {
        try await waitUntil("thumbnail request") { requestCount > 0 }
    }

    func waitForCompletion() async throws {
        try await waitUntil("thumbnail completion") { completionCount > 0 }
    }

    func waitForCancellation() async throws {
        try await waitUntil("thumbnail cancellation") { cancellationCount > 0 }
    }

    private func recordCancellation() {
        cancellationCount += 1
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition() {
            guard clock.now < deadline else {
                throw StoreTestWaitError.timedOut(description)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor CompletionProbe {
    private var isComplete = false

    func complete() {
        isComplete = true
    }

    func value() -> Bool {
        isComplete
    }
}

@MainActor
private final class WeakStoreReference {
    weak var value: DownloadStore?

    init(_ value: DownloadStore?) {
        self.value = value
    }
}

private extension VideoAnalysis {
    static func fixture(
        sourceURL: String = "https://youtube.test/video",
        title: String = "Fixture video",
        titleSource: MediaTitleSource? = .metadata,
        thumbnailURL: URL? = nil,
        videoFormats: [MediaFormat] = [],
        audioFormats: [MediaFormat] = []
    ) -> VideoAnalysis {
        VideoAnalysis(
            sourceURL: sourceURL,
            title: title,
            titleSource: titleSource,
            duration: 30,
            thumbnailURL: thumbnailURL,
            videoFormats: videoFormats,
            audioFormats: audioFormats
        )
    }
}

private extension MediaFormat {
    static func fixture(id: String) -> MediaFormat {
        MediaFormat(id: id, label: id)
    }
}

private extension PlaylistAnalysis {
    static func fixture(entryCount: Int) -> PlaylistAnalysis {
        PlaylistAnalysis(
            id: "playlist",
            title: "Fixture playlist",
            entries: (1...entryCount).map { index in
                PlaylistEntry(
                    id: "\(index)",
                    sourceURL: "https://youtube.test/watch?v=\(index)",
                    title: "Entry \(index)",
                    duration: 30,
                    thumbnailURL: nil
                )
            }
        )
    }
}

private enum StoreTestWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case let .timedOut(description):
            description
        }
    }
}

private let storePNGData = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!
