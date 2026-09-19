import XCTest
@testable import YTDownloaderPro2

final class DataRequestPresentationTests: XCTestCase {
    func testEveryLocalDeletionActionHasStablePresentation() {
        let completed = LocalDeletionActionPresentation(
            draft: .historyPreview(
                action: .clearCompletedHistory,
                jobs: [.fixture(status: .completed)]
            )
        )
        let failed = LocalDeletionActionPresentation(
            draft: .historyPreview(
                action: .clearFailedAndCancelledHistory,
                jobs: [.fixture(status: .failed)]
            )
        )
        let diagnostics = LocalDeletionActionPresentation(
            draft: .actionPreview(.clearDiagnostics)
        )
        let settings = LocalDeletionActionPresentation(
            draft: .actionPreview(.resetSettings)
        )
        let media = LocalDeletionActionPresentation(
            draft: .actionPreview(
                .deleteSelectedMediaFile,
                selectedMediaFileURL: URL(fileURLWithPath: "/Users/example/Movies/private-title.mp4")
            )
        )

        XCTAssertEqual(completed.title, "Clear Completed History")
        XCTAssertEqual(completed.symbolName, "checkmark.circle")
        XCTAssertEqual(completed.confirmationButtonTitle, "Clear History")
        XCTAssertEqual(
            completed.confirmationMessage,
            "Remove 1 completed history record(s) and their cached thumbnails?"
        )
        XCTAssertEqual(completed.severity, .destructiveRecords)
        XCTAssertEqual(completed.retainedDataDescription, "Downloaded media, settings, and diagnostics are kept.")

        XCTAssertEqual(failed.title, "Clear Failed and Cancelled History")
        XCTAssertEqual(failed.symbolName, "exclamationmark.triangle")
        XCTAssertEqual(failed.confirmationButtonTitle, "Clear History")
        XCTAssertEqual(
            failed.confirmationMessage,
            "Remove 1 failed or cancelled history record(s) and their cached thumbnails?"
        )
        XCTAssertEqual(failed.severity, .destructiveRecords)
        XCTAssertEqual(failed.retainedDataDescription, "Downloaded media, settings, and diagnostics are kept.")

        XCTAssertEqual(diagnostics.title, "Clear Diagnostics")
        XCTAssertEqual(diagnostics.symbolName, "doc.text.magnifyingglass")
        XCTAssertEqual(diagnostics.confirmationButtonTitle, "Clear Diagnostics")
        XCTAssertEqual(diagnostics.confirmationMessage, "Remove the local diagnostic log?")
        XCTAssertEqual(diagnostics.severity, .destructiveLocalData)
        XCTAssertEqual(diagnostics.retainedDataDescription, "History, thumbnails, downloaded media, and settings are kept.")

        XCTAssertEqual(settings.title, "Reset Settings")
        XCTAssertEqual(settings.symbolName, "arrow.counterclockwise")
        XCTAssertEqual(settings.confirmationButtonTitle, "Reset Settings")
        XCTAssertEqual(
            settings.confirmationMessage,
            "Restore all app settings to their defaults, including the saved output-folder selection?"
        )
        XCTAssertEqual(settings.severity, .destructiveLocalData)
        XCTAssertEqual(settings.retainedDataDescription, "History, thumbnails, downloaded media, and diagnostics are kept.")

        XCTAssertEqual(media.title, "Delete Selected Media File")
        XCTAssertEqual(media.symbolName, "trash")
        XCTAssertEqual(media.confirmationButtonTitle, "Delete File")
        XCTAssertEqual(
            media.confirmationMessage,
            "Permanently delete private-title.mp4? This cannot be undone."
        )
        XCTAssertEqual(media.severity, .irreversibleMediaDeletion)
        XCTAssertEqual(media.retainedDataDescription, "History, thumbnails, settings, and diagnostics are kept.")
    }

    func testDeletionPresentationEnablesOnlyAvailableTargetsAndSeparatesMediaDeletion() {
        let emptyCompleted = LocalDeletionActionPresentation(
            draft: .historyPreview(action: .clearCompletedHistory, jobs: [])
        )
        let populatedCompleted = LocalDeletionActionPresentation(
            draft: .historyPreview(
                action: .clearCompletedHistory,
                jobs: [.fixture(status: .completed)]
            )
        )
        let mediaWithoutSelection = LocalDeletionActionPresentation(
            draft: .actionPreview(.deleteSelectedMediaFile)
        )
        let mediaWithSelection = LocalDeletionActionPresentation(
            draft: .actionPreview(
                .deleteSelectedMediaFile,
                selectedMediaFileURL: URL(fileURLWithPath: "/Users/example/Movies/private-title.mp4")
            )
        )

        XCTAssertFalse(emptyCompleted.isEnabled)
        XCTAssertTrue(populatedCompleted.isEnabled)
        XCTAssertTrue(LocalDeletionActionPresentation(draft: .actionPreview(.clearDiagnostics)).isEnabled)
        XCTAssertTrue(LocalDeletionActionPresentation(draft: .actionPreview(.resetSettings)).isEnabled)
        XCTAssertFalse(mediaWithoutSelection.isEnabled)
        XCTAssertTrue(mediaWithSelection.isEnabled)

        XCTAssertFalse(populatedCompleted.deletesDownloadedMedia)
        XCTAssertTrue(populatedCompleted.requiresSeparateMediaFileAction)
        XCTAssertNil(populatedCompleted.selectedMediaFileName)
        XCTAssertTrue(mediaWithSelection.deletesDownloadedMedia)
        XCTAssertFalse(mediaWithSelection.requiresSeparateMediaFileAction)
        XCTAssertEqual(mediaWithSelection.selectedMediaFileName, "private-title.mp4")
        XCTAssertFalse(mediaWithSelection.confirmationMessage.contains("/Users/example"))
        XCTAssertTrue(mediaWithSelection.confirmationMessage.contains("private-title.mp4"))
    }

    func testComposerExcludesEveryOptionalValueUntilUserEnablesIt() {
        var composer = SupportReportComposer(
            category: .general,
            subject: "A subject",
            message: "A message",
            environment: .fixture(),
            incidentID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        composer.optionalValues = .init(
            sourceURL: "https://user:password@youtube.test/watch?v=private",
            mediaTitle: "Private title",
            selectedFormatID: "137+140",
            diagnosticExportName: "/Users/example/private-diagnostics.json",
            screenshotName: "/Users/example/private-screenshot.png",
            contactEmail: "person@example.test",
            mediaFileName: "/Users/example/private-video.mp4"
        )

        let draft = composer.makeDraft()

        XCTAssertEqual(draft.optionalFields, .disabled)
        XCTAssertEqual(SupportReportPreviewPresentation(draft: draft).selectedOptionalFieldCount, 0)
    }

    func testComposerIncludesOnlyEnabledValuesAndMarksActivityRevealingFields() throws {
        var composer = SupportReportComposer(
            category: .privacy,
            subject: "Privacy request",
            message: "Please inspect this exact local preview.",
            environment: .fixture(),
            incidentID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        composer.enabledOptionalFields = Set(SupportReportPreviewPresentation.OptionalFieldKind.allCases)
        composer.optionalValues = .init(
            sourceURL: "https://user:password@youtube.test/watch?v=private",
            mediaTitle: "Private title",
            selectedFormatID: "137+140",
            diagnosticExportName: "/Users/example/private-diagnostics.json",
            screenshotName: "/Users/example/private-screenshot.png",
            contactEmail: " person@example.test ",
            mediaFileName: "/Users/example/private-video.mp4"
        )

        let draft = composer.makeDraft()
        let presentation = SupportReportPreviewPresentation(draft: draft)

        XCTAssertEqual(draft.optionalFields.sourceURL, "https://youtube.test/watch?v=private")
        XCTAssertEqual(draft.optionalFields.mediaTitle, "Private title")
        XCTAssertEqual(draft.optionalFields.selectedFormatID, "137+140")
        XCTAssertEqual(draft.optionalFields.diagnosticExportName, "private-diagnostics.json")
        XCTAssertEqual(draft.optionalFields.screenshotName, "private-screenshot.png")
        XCTAssertEqual(draft.optionalFields.contactEmail, "person@example.test")
        XCTAssertEqual(draft.optionalFields.mediaFileName, "private-video.mp4")
        XCTAssertEqual(presentation.routing, .bypassesPaidPriorityRules)
        XCTAssertEqual(
            Set(presentation.optionalFields.filter(\.isSelected).map(\.kind)),
            Set(SupportReportPreviewPresentation.OptionalFieldKind.allCases)
        )
        XCTAssertEqual(
            presentation.selectedActivityRevealingFields,
            [.sourceURL, .mediaTitle, .selectedFormatID, .mediaFile]
        )
    }

    func testExactJSONPreviewDecodesToReviewedDraft() throws {
        let composer = SupportReportComposer(
            category: .downloadFailure,
            subject: "Download failed",
            message: "The reviewed payload should be exact.",
            environment: .fixture(),
            incidentID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )
        let draft = composer.makeDraft()

        let preview = try SupportReportJSONPreview(draft: draft)

        XCTAssertEqual(
            try JSONDecoder().decode(SupportReportDraft.self, from: Data(preview.payload.utf8)),
            draft
        )
        XCTAssertTrue(preview.payload.contains("\n"))
    }

    func testSupportReportPresentationKeepsOptionalFieldsDisabledAndLocalOnlyByDefault() {
        let draft = SupportReportDraft.defaultPreview(
            category: .privacy,
            subject: "Privacy request",
            message: "Please review the local preview.",
            environment: .fixture(),
            incidentID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )

        let presentation = SupportReportPreviewPresentation(draft: draft)

        XCTAssertEqual(presentation.routing, .bypassesPaidPriorityRules)
        XCTAssertEqual(presentation.optionalFields.map(\.kind), SupportReportPreviewPresentation.OptionalFieldKind.allCases)
        XCTAssertTrue(presentation.optionalFields.allSatisfy { !$0.isSelectedByDefault })
        XCTAssertTrue(presentation.optionalFields.allSatisfy(\.isUserControlled))
        XCTAssertFalse(presentation.enablesExternalSubmission)
        XCTAssertFalse(presentation.sendsEmail)
        XCTAssertFalse(presentation.usesSupportVendor)
        XCTAssertEqual(presentation.selectedOptionalFieldCount, 0)

        let activityFields = presentation.optionalFields.filter(\.canRevealDownloadActivity)
        XCTAssertEqual(
            Set(activityFields.map(\.kind)),
            [.sourceURL, .mediaTitle, .selectedFormatID, .mediaFile]
        )
    }

    func testLocalExportAndDeletionPresentationsAreSideEffectFreeAndSeparateMediaDeletion() {
        let export = LocalDataExportDraft.defaultPreview(
            appVersion: "2.0.0-test",
            releaseChannel: "internal",
            jobs: [.fixture(status: .completed)],
            settings: .defaults
        )
        let exportPresentation = LocalExportPreviewPresentation(draft: export)

        XCTAssertEqual(exportPresentation.destination, .localPreviewOnly)
        XCTAssertFalse(exportPresentation.writesLocalFile)
        XCTAssertFalse(exportPresentation.uploadsExternally)
        XCTAssertFalse(exportPresentation.sendsEmail)
        XCTAssertEqual(exportPresentation.sectionCount, export.manifest.selectedSections.count)
        XCTAssertEqual(exportPresentation.jobCount, 1)

        let clearHistory = LocalDeletionDraft.historyPreview(
            action: .clearCompletedHistory,
            jobs: [.fixture(status: .completed)]
        )
        let mediaDeletion = LocalDeletionDraft.actionPreview(
            .deleteSelectedMediaFile,
            selectedMediaFileURL: URL(fileURLWithPath: "/Users/example/Movies/private-title.mp4")
        )

        let clearPresentation = LocalDeletionPreviewPresentation(draft: clearHistory)
        let mediaPresentation = LocalDeletionPreviewPresentation(draft: mediaDeletion)

        XCTAssertFalse(clearPresentation.performsDeletion)
        XCTAssertFalse(clearPresentation.deletesDownloadedMedia)
        XCTAssertTrue(clearPresentation.requiresSeparateMediaFileAction)
        XCTAssertEqual(clearPresentation.jobRecordCount, 1)
        XCTAssertEqual(clearPresentation.selectedMediaFileName, nil)

        XCTAssertFalse(mediaPresentation.performsDeletion)
        XCTAssertTrue(mediaPresentation.deletesDownloadedMedia)
        XCTAssertFalse(mediaPresentation.requiresSeparateMediaFileAction)
        XCTAssertEqual(mediaPresentation.selectedMediaFileName, "private-title.mp4")
        XCTAssertFalse(mediaPresentation.selectedMediaFileName?.contains("/Users/example") == true)
    }
}

private extension SupportReportDraft.Environment {
    static func fixture() -> SupportReportDraft.Environment {
        SupportReportDraft.Environment(
            appVersion: "2.0.0-test",
            releaseChannel: "internal",
            macOSVersion: "14.6",
            architecture: "arm64",
            localeIdentifier: "zh-Hant"
        )
    }
}
