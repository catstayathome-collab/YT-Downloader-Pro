import XCTest
@testable import YTDownloaderPro2

final class DataRequestPresentationTests: XCTestCase {
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
