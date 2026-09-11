import XCTest
@testable import YTDownloaderPro2

final class DownloadCenterViewTests: XCTestCase {
    func testURLInputPresentationReplacesLineBreaksWithoutDiscardingLinks() {
        let input = "https://youtu.be/one\r\nhttps://youtu.be/two\nhttps://youtu.be/three"

        XCTAssertEqual(
            URLInputPresentation.displayText(for: input),
            "https://youtu.be/one https://youtu.be/two https://youtu.be/three"
        )
    }

    func testURLInputClearsOnlyAfterAtLeastOneURLIsAccepted() {
        XCTAssertTrue(URLInputPresentation.shouldClearInput(after: URLInputSubmissionResult(
            acceptedCount: 2,
            rejectedCount: 1,
            duplicateCount: 1
        )))
        XCTAssertFalse(URLInputPresentation.shouldClearInput(after: URLInputSubmissionResult(
            acceptedCount: 0,
            rejectedCount: 1,
            duplicateCount: 0
        )))
    }

    func testURLInputFeedbackUsesCountsWithoutEchoingSubmittedURLs() throws {
        let secretURL = "https://example.test/private-video"
        let result = URLInputSubmissionResult(acceptedCount: 2, rejectedCount: 1, duplicateCount: 1)

        for identifier in ["en", "ja", "zh-Hant"] {
            let feedback = try XCTUnwrap(
                URLInputPresentation.feedback(for: result, locale: Locale(identifier: identifier))
            )
            XCTAssertTrue(feedback.contains("2"))
            XCTAssertTrue(feedback.contains("1"))
            XCTAssertFalse(feedback.contains(secretURL))
        }
    }

    func testNoValidURLFeedbackIsLocalizedAndDoesNotClearInput() throws {
        let result = URLInputSubmissionResult(acceptedCount: 0, rejectedCount: 2, duplicateCount: 0)

        let values = ["en", "ja", "zh-Hant"].map {
            URLInputPresentation.feedback(for: result, locale: Locale(identifier: $0))
        }

        XCTAssertTrue(values.allSatisfy { $0?.isEmpty == false })
        XCTAssertEqual(Set(values.compactMap { $0 }).count, 3)
        XCTAssertFalse(URLInputPresentation.shouldClearInput(after: result))
    }

    func testBulkToolbarExplainsDisabledCompletedOnlyStateAndKeepsClearHistoryAvailable() {
        let presentation = DownloadCenterBulkPresentation(jobs: [.fixture(status: .completed)])

        XCTAssertFalse(presentation.isEnabled(.startAll))
        XCTAssertFalse(presentation.isEnabled(.pauseAll))
        XCTAssertFalse(presentation.isEnabled(.resumeAll))
        XCTAssertFalse(presentation.isEnabled(.cancelActiveAndWaiting))
        XCTAssertTrue(presentation.isEnabled(.clearHistory))
        XCTAssertNotEqual(presentation.symbol(for: .startAll), presentation.symbol(for: .resumeAll))
    }

    func testConfirmationAndAutomaticUpdateUseOneAlertChannelWithConfirmationPriority() {
        let notice = UpdateNotice(id: 7, result: .upToDate, origin: .automatic)

        let presented = DownloadCenterPresentedAlert.resolve(
            confirmation: .clearHistory,
            automaticUpdate: notice
        )

        XCTAssertEqual(presented, .confirmation(.clearHistory))
        XCTAssertEqual(
            DownloadCenterPresentedAlert.resolve(confirmation: nil, automaticUpdate: notice),
            .automaticUpdate(notice)
        )
    }

    func testLegacySettingsLauncherFallsBackToPreferencesSelector() {
        var attempted: [String] = []

        let opened = SettingsWindowLauncher.openLegacy { selector in
            attempted.append(NSStringFromSelector(selector))
            return selector == Selector(("showPreferencesWindow:"))
        }

        XCTAssertTrue(opened)
        XCTAssertEqual(attempted, ["showSettingsWindow:", "showPreferencesWindow:"])
    }

    func testLegacySettingsLauncherUsesStandardCommandMenuItemBeforePrivateSelectors() {
        var selectorAttempts = 0

        let opened = SettingsWindowLauncher.openLegacy(
            openMenuItem: { true },
            sendAction: { _ in
                selectorAttempts += 1
                return false
            }
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(selectorAttempts, 0)
    }

    func testLegacySettingsLauncherReportsFailureAfterEveryFallbackIsTried() {
        var attempted: [String] = []

        let opened = SettingsWindowLauncher.openLegacy(
            openMenuItem: { false },
            sendAction: { selector in
                attempted.append(NSStringFromSelector(selector))
                return false
            }
        )

        XCTAssertFalse(opened)
        XCTAssertEqual(attempted, ["showSettingsWindow:", "showPreferencesWindow:"])
    }

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

    func testBatchAnalysisPlaceholderOffersCancelWithoutInactivePauseAction() {
        let placeholder = DownloadJob.fixture(status: .analyzing, awaitsBatchAnalysis: true)

        XCTAssertEqual(DownloadCardPresentation(job: placeholder).actions, [.cancel])
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

    func testFailedCardUsesEditAndRetryOnlyForActionableOptionCategories() {
        let editable: Set<DownloadFailure.Category> = [
            .authenticationRequired,
            .formatReselectionRequired,
            .outputPermissionDenied,
            .diskFull
        ]

        for category in DownloadFailure.Category.allCases {
            var job = DownloadJob.fixture(status: .failed)
            job.failure = DownloadFailure(category: category)
            let actions = DownloadCardPresentation(job: job).actions

            if editable.contains(category) {
                XCTAssertEqual(actions, [.editAndRetry, .errorDetails, .removeRecord], category.rawValue)
            } else {
                XCTAssertEqual(actions, [.retry, .errorDetails, .removeRecord], category.rawValue)
            }
        }
    }

    func testFailedCardTextIsBoundedLocalizedAndNeverUsesTechnicalDetail() throws {
        let secret = "raw-helper-secret"
        var job = DownloadJob.fixture(status: .failed)
        job.failure = DownloadFailure(
            category: .authenticationRequired,
            technicalDetail: "helper stderr \(secret)"
        )
        let presentation = DownloadCardPresentation(job: job)

        for identifier in ["en", "ja", "zh-Hant"] {
            let text = try XCTUnwrap(presentation.failureText(locale: Locale(identifier: identifier)))
            XCTAssertFalse(text.summary.isEmpty)
            XCTAssertFalse(text.recovery.isEmpty)
            XCTAssertFalse(text.summary.contains(secret))
            XCTAssertFalse(text.recovery.contains(secret))
            XCTAssertNotEqual(text.summary, job.failure?.technicalDetail)
            XCTAssertNotEqual(text.recovery, job.failure?.technicalDetail)
        }

        XCTAssertEqual(presentation.layout.failureSummaryLineCount, 1)
        XCTAssertEqual(presentation.layout.failureRecoveryLineCount, 2)
        XCTAssertLessThanOrEqual(presentation.layout.minimumWidth, 532)
    }

    func testOnlyDestructiveCardActionsRequireConfirmation() {
        let presentation = DownloadCardPresentation(job: .fixture(status: .completed))
        let immediateActions: [DownloadCardAction] = [
            .edit, .startNow, .pause, .resume, .cancel, .play,
            .revealInFinder, .retry, .editAndRetry, .errorDetails, .reAdd
        ]

        XCTAssertEqual(presentation.confirmation(for: .removeRecord), .removeRecord)
        XCTAssertTrue(immediateActions.allSatisfy { presentation.confirmation(for: $0) == nil })
        XCTAssertEqual(
            DownloadCardPresentation(job: .fixture(status: .merging)).confirmation(for: .cancelWithConfirmation),
            .cancelMerging
        )
    }

    func testClearHistoryConfirmationSaysMediaRemainsAndHistoryCacheAreRemoved() {
        let confirmation = DownloadCenterAction.clearHistory.confirmation

        XCTAssertEqual(confirmation, .clearHistory)
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
        XCTAssertEqual(Set(layouts.map(\.minimumWidth)).count, 1)
        XCTAssertEqual(Set(layouts.map(\.failureSummaryLineCount)).count, 1)
        XCTAssertEqual(Set(layouts.map(\.failureRecoveryLineCount)).count, 1)
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
