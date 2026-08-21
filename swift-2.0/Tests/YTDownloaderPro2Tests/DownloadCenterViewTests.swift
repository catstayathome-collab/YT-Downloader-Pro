import XCTest
@testable import YTDownloaderPro2

final class DownloadCenterViewTests: XCTestCase {
    func testMergingCardDoesNotExposePause() {
        let presentation = DownloadCardPresentation(job: .fixture(status: .merging))

        XCTAssertFalse(presentation.actions.contains(.pause))
        XCTAssertEqual(presentation.actions, [.cancelWithConfirmation])
    }

    func testCompletedCardExposesPlayRevealAndRemove() {
        let actions = DownloadCardPresentation(job: .fixture(status: .completed)).actions

        XCTAssertEqual(actions, [.play, .revealInFinder, .removeRecord])
    }

    func testEveryNonterminalCardUsesItsApprovedActionSet() {
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .queued)).actions,
            [.edit, .startNow, .cancel]
        )
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .analyzing)).actions,
            [.pause, .cancel]
        )
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .downloading)).actions,
            [.pause, .cancel]
        )
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .paused)).actions,
            [.resume, .cancel]
        )
    }

    func testFailedAndCancelledCardsUseRecordActions() {
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .failed)).actions,
            [.retry, .errorDetails, .removeRecord]
        )
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .cancelled)).actions,
            [.reAdd, .removeRecord]
        )
    }
}
