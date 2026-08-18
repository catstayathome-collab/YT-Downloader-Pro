import XCTest
@testable import YTDownloaderPro2

final class ModelsTests: XCTestCase {
    func testDefaultsUseBestQualityAndFiveWorkers() {
        XCTAssertEqual(DownloadOptions.defaults.videoQuality, .best)
        XCTAssertEqual(DownloadOptions.defaults.audioQuality, .best)
        XCTAssertEqual(AppSettings.defaults.maximumConcurrentDownloads, 5)
    }

    func testConcurrencyClampsToSupportedRange() {
        XCTAssertEqual(AppSettings(maximumConcurrentDownloads: 0).maximumConcurrentDownloads, 1)
        XCTAssertEqual(AppSettings(maximumConcurrentDownloads: 99).maximumConcurrentDownloads, 10)
    }

    func testMergingCannotPause() {
        XCTAssertFalse(DownloadStatus.merging.canPause)

        var job = DownloadJob.fixture(status: .merging)

        XCTAssertThrowsError(try job.transition(to: .paused))
    }

    func testTerminalJobsCannotReturnToActiveStatus() {
        var job = DownloadJob.fixture(status: .completed)

        XCTAssertThrowsError(try job.transition(to: .downloading))
    }

    func testQueuedJobCannotCompleteWithoutRunning() {
        var job = DownloadJob.fixture(status: .queued)

        XCTAssertThrowsError(try job.transition(to: .completed))
    }

    func testSidebarMappingMatchesDesign() {
        XCTAssertEqual(DownloadStatus.queued.sidebarSection, .running)
        XCTAssertEqual(DownloadStatus.cancelled.sidebarSection, .stopped)
        XCTAssertEqual(DownloadStatus.failed.sidebarSection, .failed)
    }
}
