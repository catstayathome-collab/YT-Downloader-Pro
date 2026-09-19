import Foundation

struct SupportReportComposer: Equatable, Sendable {
    struct OptionalValues: Equatable, Sendable {
        var sourceURL = ""
        var mediaTitle = ""
        var selectedFormatID = ""
        var diagnosticExportName = ""
        var screenshotName = ""
        var contactEmail = ""
        var mediaFileName = ""
    }

    var category: SupportReportDraft.Category
    var subject: String
    var message: String
    var environment: SupportReportDraft.Environment
    var incidentID: UUID
    var selectedJob: DownloadJob?
    var selectedFailure: DownloadFailure?
    var diagnosticLines: [String]
    var enabledOptionalFields: Set<SupportReportPreviewPresentation.OptionalFieldKind>
    var optionalValues: OptionalValues

    init(
        category: SupportReportDraft.Category,
        subject: String,
        message: String,
        environment: SupportReportDraft.Environment,
        incidentID: UUID = UUID(),
        selectedJob: DownloadJob? = nil,
        selectedFailure: DownloadFailure? = nil,
        diagnosticLines: [String] = [],
        enabledOptionalFields: Set<SupportReportPreviewPresentation.OptionalFieldKind> = [],
        optionalValues: OptionalValues = OptionalValues()
    ) {
        self.category = category
        self.subject = subject
        self.message = message
        self.environment = environment
        self.incidentID = incidentID
        self.selectedJob = selectedJob
        self.selectedFailure = selectedFailure
        self.diagnosticLines = diagnosticLines
        self.enabledOptionalFields = enabledOptionalFields
        self.optionalValues = optionalValues
    }

    func makeDraft() -> SupportReportDraft {
        var draft = SupportReportDraft.defaultPreview(
            category: category,
            subject: subject,
            message: message,
            environment: environment,
            incidentID: incidentID,
            selectedJob: selectedJob,
            selectedFailure: selectedFailure,
            diagnosticLines: diagnosticLines
        )
        draft.optionalFields = SupportReportDraft.OptionalFields(
            sourceURL: enabledURL(.sourceURL, optionalValues.sourceURL),
            mediaTitle: enabledText(.mediaTitle, optionalValues.mediaTitle),
            selectedFormatID: enabledText(.selectedFormatID, optionalValues.selectedFormatID),
            diagnosticExportName: enabledFileName(.diagnosticExport, optionalValues.diagnosticExportName),
            screenshotName: enabledFileName(.screenshot, optionalValues.screenshotName),
            contactEmail: enabledText(.contactEmail, optionalValues.contactEmail),
            mediaFileName: enabledFileName(.mediaFile, optionalValues.mediaFileName)
        )
        return draft
    }

    private func enabledText(
        _ kind: SupportReportPreviewPresentation.OptionalFieldKind,
        _ value: String
    ) -> String? {
        guard enabledOptionalFields.contains(kind) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func enabledURL(
        _ kind: SupportReportPreviewPresentation.OptionalFieldKind,
        _ value: String
    ) -> String? {
        guard let trimmed = enabledText(kind, value) else { return nil }
        return MediaURLValidator.credentialFreeEquivalent(of: trimmed)
    }

    private func enabledFileName(
        _ kind: SupportReportPreviewPresentation.OptionalFieldKind,
        _ value: String
    ) -> String? {
        guard let trimmed = enabledText(kind, value) else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

struct SupportReportJSONPreview: Equatable, Sendable {
    let payload: String

    init(draft: SupportReportDraft) throws {
        payload = String(
            decoding: try SupportReportPayloadEncoder.encode(draft),
            as: UTF8.self
        )
    }
}

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
        var isSelected: Bool
        var isUserControlled: Bool
        var canRevealDownloadActivity: Bool
    }

    var routing: Routing
    var optionalFields: [OptionalField]
    var enablesExternalSubmission: Bool
    var sendsEmail: Bool
    var usesSupportVendor: Bool
    var selectedOptionalFieldCount: Int
    var selectedActivityRevealingFields: Set<OptionalFieldKind>

    init(draft: SupportReportDraft) {
        routing = draft.bypassesPaidPriorityRules ? .bypassesPaidPriorityRules : .standardPaidPriority
        let selectedKinds = draft.optionalFields.selectedKinds
        optionalFields = OptionalFieldKind.allCases.map { kind in
            OptionalField(
                kind: kind,
                isSelectedByDefault: false,
                isSelected: selectedKinds.contains(kind),
                isUserControlled: true,
                canRevealDownloadActivity: kind.canRevealDownloadActivity
            )
        }
        enablesExternalSubmission = false
        sendsEmail = false
        usesSupportVendor = false
        selectedOptionalFieldCount = draft.optionalFields.selectedFieldCount
        selectedActivityRevealingFields = Set(
            optionalFields.lazy
                .filter { $0.isSelected && $0.canRevealDownloadActivity }
                .map(\.kind)
        )
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
    var selectedKinds: Set<SupportReportPreviewPresentation.OptionalFieldKind> {
        var kinds: Set<SupportReportPreviewPresentation.OptionalFieldKind> = []
        if sourceURL != nil { kinds.insert(.sourceURL) }
        if mediaTitle != nil { kinds.insert(.mediaTitle) }
        if selectedFormatID != nil { kinds.insert(.selectedFormatID) }
        if diagnosticExportName != nil { kinds.insert(.diagnosticExport) }
        if screenshotName != nil { kinds.insert(.screenshot) }
        if contactEmail != nil { kinds.insert(.contactEmail) }
        if mediaFileName != nil { kinds.insert(.mediaFile) }
        return kinds
    }

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
