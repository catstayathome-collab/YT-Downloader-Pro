import Foundation

struct SupportReportPreviewPresentation: Equatable, Sendable {
    enum Routing: Equatable, Sendable {
        case standardPaidPriority
        case bypassesPaidPriorityRules
    }

    enum OptionalFieldKind: String, CaseIterable, Equatable, Hashable, Sendable {
        case sourceURL
        case mediaTitle
        case selectedFormatID
        case diagnosticExport
        case screenshot
        case contactEmail
        case mediaFile

        var canRevealDownloadActivity: Bool {
            switch self {
            case .sourceURL, .mediaTitle, .selectedFormatID, .mediaFile:
                true
            case .diagnosticExport, .screenshot, .contactEmail:
                false
            }
        }
    }

    struct OptionalField: Equatable, Sendable {
        var kind: OptionalFieldKind
        var isSelectedByDefault: Bool
        var isUserControlled: Bool
        var canRevealDownloadActivity: Bool
    }

    var routing: Routing
    var optionalFields: [OptionalField]
    var enablesExternalSubmission: Bool
    var sendsEmail: Bool
    var usesSupportVendor: Bool
    var selectedOptionalFieldCount: Int

    init(draft: SupportReportDraft) {
        routing = draft.bypassesPaidPriorityRules ? .bypassesPaidPriorityRules : .standardPaidPriority
        optionalFields = OptionalFieldKind.allCases.map { kind in
            OptionalField(
                kind: kind,
                isSelectedByDefault: false,
                isUserControlled: true,
                canRevealDownloadActivity: kind.canRevealDownloadActivity
            )
        }
        enablesExternalSubmission = false
        sendsEmail = false
        usesSupportVendor = false
        selectedOptionalFieldCount = draft.optionalFields.selectedFieldCount
    }
}

struct LocalExportPreviewPresentation: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case localPreviewOnly
    }

    var destination: Destination
    var writesLocalFile: Bool
    var uploadsExternally: Bool
    var sendsEmail: Bool
    var sectionCount: Int
    var jobCount: Int
    var thumbnailReferenceCount: Int
    var diagnosticLineCount: Int

    init(draft: LocalDataExportDraft) {
        destination = .localPreviewOnly
        writesLocalFile = false
        uploadsExternally = false
        sendsEmail = false
        sectionCount = draft.manifest.selectedSections.count
        jobCount = draft.jobs.count
        thumbnailReferenceCount = draft.thumbnailReferences.count
        diagnosticLineCount = draft.diagnosticExcerpt.count
    }
}

struct LocalDeletionPreviewPresentation: Equatable, Sendable {
    var performsDeletion: Bool
    var deletesDownloadedMedia: Bool
    var requiresSeparateMediaFileAction: Bool
    var jobRecordCount: Int
    var thumbnailCacheFileCount: Int
    var selectedMediaFileName: String?

    init(draft: LocalDeletionDraft) {
        performsDeletion = false
        deletesDownloadedMedia = draft.deletesDownloadedMedia
        requiresSeparateMediaFileAction = draft.requiresSeparateMediaFileAction
        jobRecordCount = draft.jobRecordIDs.count
        thumbnailCacheFileCount = draft.thumbnailCacheNames.count
        selectedMediaFileName = draft.selectedMediaFileName
    }
}

private extension SupportReportDraft.OptionalFields {
    var selectedFieldCount: Int {
        [
            sourceURL,
            mediaTitle,
            selectedFormatID,
            diagnosticExportName,
            screenshotName,
            contactEmail,
            mediaFileName
        ].compactMap { $0 }.count
    }
}
