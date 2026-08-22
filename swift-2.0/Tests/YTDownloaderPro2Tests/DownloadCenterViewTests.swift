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

    func testOnlyDestructiveCardActionsRequireConfirmation() {
        let presentation = DownloadCardPresentation(job: .fixture(status: .completed))
        let immediateActions: [DownloadCardAction] = [
            .edit, .startNow, .pause, .resume, .cancel, .play,
            .revealInFinder, .retry, .errorDetails, .reAdd
        ]

        XCTAssertEqual(presentation.confirmation(for: .removeRecord), .removeRecord)
        XCTAssertTrue(immediateActions.allSatisfy { presentation.confirmation(for: $0) == nil })
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .merging)).confirmation(for: .cancelWithConfirmation),
            .cancelMerging
        )
    }

    func testClearCompletedConfirmationSaysMediaRemainsAndHistoryCacheAreRemoved() {
        let confirmation = DownloadCenterAction.clearCompleted.confirmation

        XCTAssertEqual(confirmation, .clearCompleted)
        XCTAssertEqual(DownloadCenterAction.cancelActiveAndWaiting.confirmation, .cancelActiveAndWaiting)
        XCTAssertTrue(confirmation?.message.contains("media files will remain") == true)
        XCTAssertTrue(confirmation?.message.contains("history records") == true)
        XCTAssertTrue(confirmation?.message.contains("cached thumbnails") == true)
        XCTAssertNil(DownloadCenterAction.startAll.confirmation)
        XCTAssertNil(DownloadCenterAction.pauseAll.confirmation)
        XCTAssertNil(DownloadCenterAction.resumeAll.confirmation)
    }

    func testRemoveRecordConfirmationSaysMediaRemainsAndOnlyHistoryCacheAreRemoved() {
        let confirmation = DownloadConfirmation.removeRecord

        XCTAssertTrue(confirmation.message.contains("media file will remain"))
        XCTAssertTrue(confirmation.message.contains("history record"))
        XCTAssertTrue(confirmation.message.contains("cached thumbnail"))
    }

    func testCompletedOutputActionsRequireAnExistingRegularFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("finished.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let directoryURL = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let missingURL = root.appendingPathComponent("missing.mp4")

        let available = DownloadCardPresentation(job: .fixture(status: .completed, outputURL: mediaURL))
        let directory = DownloadCardPresentation(job: .fixture(status: .completed, outputURL: directoryURL))
        let missing = DownloadCardPresentation(job: .fixture(status: .completed, outputURL: missingURL))

        XCTAssertTrue(available.isEnabled(.play))
        XCTAssertTrue(available.isEnabled(.revealInFinder))
        XCTAssertEqual(available.validatedOutputFileURL, mediaURL)
        XCTAssertFalse(directory.isEnabled(.play))
        XCTAssertFalse(missing.isEnabled(.revealInFinder))
        XCTAssertNil(directory.validatedOutputFileURL)
        XCTAssertNil(missing.validatedOutputFileURL)
        XCTAssertEqual(missing.help(for: .play), "Play unavailable: the file is missing or is not a regular file")
        XCTAssertEqual(
            missing.accessibilityLabel(for: .revealInFinder),
            "Reveal in Finder, unavailable because the file is missing or is not a regular file"
        )
    }

    func testApprovedAppearanceIsLightWithNearWhiteNeutralSurfaces() {
        let palette = DownloadCenterAppearance.palette

        XCTAssertEqual(DownloadCenterAppearance.preferredScheme, .light)
        XCTAssertGreaterThanOrEqual(palette.windowBackground.relativeLuminance, 0.9)
        XCTAssertGreaterThanOrEqual(palette.cardBackground.relativeLuminance, 0.95)
        XCTAssertLessThan(palette.primaryText.relativeLuminance, 0.2)
        XCTAssertGreaterThanOrEqual(palette.primaryText.contrastRatio(with: palette.windowBackground), 7)
        XCTAssertGreaterThanOrEqual(palette.secondaryText.contrastRatio(with: palette.windowBackground), 4.5)
        XCTAssertEqual(palette.windowBackground.red, palette.windowBackground.green, accuracy: 0.01)
        XCTAssertEqual(palette.windowBackground.green, palette.windowBackground.blue, accuracy: 0.01)
    }

    func testCardLayoutReservesStableTitleAndLifecycleRowsForEveryStatus() {
        let layouts = DownloadStatus.allCases.map {
            DownloadCardPresentation(job: .fixture(status: $0)).layout
        }

        XCTAssertEqual(Set(layouts.map(\.cardHeight)).count, 1)
        XCTAssertTrue(layouts.allSatisfy { $0.titleLineCount == 2 })
        XCTAssertTrue(layouts.allSatisfy(\.reservesProgressRow))
        XCTAssertTrue(layouts.allSatisfy(\.reservesDetailRow))
        XCTAssertTrue(layouts.allSatisfy(\.reservesOutputPathRow))
        XCTAssertGreaterThanOrEqual(layouts[0].cardHeight, layouts[0].thumbnailHeight)
    }

    func testErrorDetailsPresentationBoundsSheetAndKeepsDoneOutsideTechnicalScroll() {
        let layout = ErrorDetailsPresentation.layout

        XCTAssertLessThanOrEqual(layout.sheetWidth, 600)
        XCTAssertLessThanOrEqual(layout.sheetHeight, 480)
        XCTAssertLessThan(layout.technicalDetailHeight, layout.sheetHeight)
        XCTAssertTrue(layout.wrapsLongLines)
        XCTAssertTrue(layout.doneButtonOutsideTechnicalScroll)
        XCTAssertLessThanOrEqual(
            layout.headerHeight
                + layout.technicalDetailHeight
                + layout.doneRowHeight
                + (layout.contentSpacing * 3)
                + layout.verticalPadding,
            layout.sheetHeight
        )
    }
}
