import Foundation

enum L10n {
    static let supportedLocaleIdentifiers = ["en", "ja", "zh-Hant"]

    enum Key: String, CaseIterable, Sendable {
        case appSettings = "app.settings"
        case accountSettingsTitle = "account.settings.title"
        case accountDevelopmentMode = "account.developmentMode"
        case accountSignInPrompt = "account.signIn.prompt"
        case accountSignInOrViewPlans = "account.signInOrViewPlans"
        case accountSignInGoogle = "account.signIn.google"
        case accountSignInApple = "account.signIn.apple"
        case accountFreeNoSignIn = "account.free.noSignIn"
        case accountCurrentPlan = "account.currentPlan"
        case accountFreePlan = "account.plan.free"
        case accountTestProPlan = "account.plan.testPro"
        case accountSigningIn = "account.signingIn"
        case accountRestoring = "account.restoring"
        case accountDownloadsUnaffected = "account.downloadsUnaffected"
        case accountReauthenticate = "account.reauthenticate"
        case accountFreeStillAvailable = "account.freeStillAvailable"
        case accountUnavailable = "account.unavailable"
        case accountOpenSettingsRetry = "account.openSettingsRetry"
        case accountRetry = "account.retry"
        case accountSignOut = "account.signOut"
        case accountSignOutPreservesData = "account.signOut.preservesData"
        case accountProviderGoogle = "account.provider.google"
        case accountProviderApple = "account.provider.apple"
        case accountErrorProviderUnavailable = "account.error.providerUnavailable"
        case accountErrorInvalidSession = "account.error.invalidSession"
        case accountErrorExpiredSession = "account.error.expiredSession"
        case accountErrorStorageUnavailable = "account.error.storageUnavailable"
        case accountErrorRemovalFailed = "account.error.removalFailed"
        case accountErrorSignInFailed = "account.error.signInFailed"
        case commonAddSelected = "common.addSelected"
        case commonAddToQueue = "common.addToQueue"
        case commonCancel = "common.cancel"
        case commonChoose = "common.choose"
        case commonClose = "common.close"
        case commonDone = "common.done"
        case commonReview = "common.review"
        case commonSave = "common.save"
        case confirmationCancelActiveMessage = "confirmation.cancelActive.message"
        case confirmationCancelActiveTitle = "confirmation.cancelActive.title"
        case confirmationCancelDownloadButton = "confirmation.cancelDownload.button"
        case confirmationCancelDownloadsButton = "confirmation.cancelDownloads.button"
        case confirmationCancelMergingMessage = "confirmation.cancelMerging.message"
        case confirmationCancelMergingTitle = "confirmation.cancelMerging.title"
        case confirmationClearHistoryButton = "confirmation.clearHistory.button"
        case confirmationClearHistoryMessage = "confirmation.clearHistory.message"
        case confirmationClearHistoryTitle = "confirmation.clearHistory.title"
        case confirmationRemoveRecordButton = "confirmation.removeRecord.button"
        case confirmationRemoveRecordMessage = "confirmation.removeRecord.message"
        case confirmationRemoveRecordTitle = "confirmation.removeRecord.title"
        case downloadActionCancel = "download.action.cancel"
        case downloadActionEdit = "download.action.edit"
        case downloadActionEditAndRetry = "download.action.editAndRetry"
        case downloadActionErrorDetails = "download.action.errorDetails"
        case downloadActionFileUnavailable = "download.action.fileUnavailable"
        case downloadActionPause = "download.action.pause"
        case downloadActionPlay = "download.action.play"
        case downloadActionPlayUnavailable = "download.action.playUnavailable"
        case downloadActionReAdd = "download.action.reAdd"
        case downloadActionRemoveRecord = "download.action.removeRecord"
        case downloadActionResume = "download.action.resume"
        case downloadActionRetry = "download.action.retry"
        case downloadActionReveal = "download.action.reveal"
        case downloadActionRevealUnavailable = "download.action.revealUnavailable"
        case downloadActionStartNow = "download.action.startNow"
        case downloadCardDetailETA = "download.card.detail.eta"
        case downloadCardDetailSpeed = "download.card.detail.speed"
        case downloadCardDetailTransfer = "download.card.detail.transfer"
        case downloadCardDetailTransferETA = "download.card.detail.transferEta"
        case downloadCardDetailTransferSpeed = "download.card.detail.transferSpeed"
        case downloadCardDetailTransferSpeedETA = "download.card.detail.transferSpeedEta"
        case downloadCardFormatMP3 = "download.card.format.mp3"
        case downloadCardFormatMP4 = "download.card.format.mp4"
        case downloadCardProgress = "download.card.progress"
        case downloadCardUnknown = "download.card.unknown"
        case downloadCardUnknownSize = "download.card.unknownSize"
        case downloadStatusAnalyzing = "download.status.analyzing"
        case downloadStatusCancelled = "download.status.cancelled"
        case downloadStatusCompleted = "download.status.completed"
        case downloadStatusDownloading = "download.status.downloading"
        case downloadStatusFailed = "download.status.failed"
        case downloadStatusFinishing = "download.status.finishing"
        case downloadStatusPaused = "download.status.paused"
        case downloadStatusQueued = "download.status.queued"
        case downloadCenterAnalyze = "downloadCenter.analyze"
        case downloadCenterAnalyzing = "downloadCenter.analyzing"
        case downloadCenterBatchAnalyzingTitle = "downloadCenter.batch.analyzingTitle"
        case downloadCenterBatchPlaylistEmpty = "downloadCenter.batch.playlistEmpty"
        case downloadCenterBulkCancel = "downloadCenter.bulk.cancel"
        case downloadCenterBulkClearHistory = "downloadCenter.bulk.clearHistory"
        case downloadCenterBulkPause = "downloadCenter.bulk.pause"
        case downloadCenterBulkResume = "downloadCenter.bulk.resume"
        case downloadCenterBulkStart = "downloadCenter.bulk.start"
        case downloadCenterEmpty = "downloadCenter.empty"
        case downloadCenterInputAccepted = "downloadCenter.input.accepted"
        case downloadCenterInputDuplicateSkipped = "downloadCenter.input.duplicateSkipped"
        case downloadCenterInputInvalidSkipped = "downloadCenter.input.invalidSkipped"
        case downloadCenterInputNoValidURL = "downloadCenter.input.noValidURL"
        case downloadCenterSidebarAll = "downloadCenter.sidebar.all"
        case downloadCenterSidebarCompleted = "downloadCenter.sidebar.completed"
        case downloadCenterSidebarFailed = "downloadCenter.sidebar.failed"
        case downloadCenterSidebarRunning = "downloadCenter.sidebar.running"
        case downloadCenterSidebarStopped = "downloadCenter.sidebar.stopped"
        case downloadCenterTitle = "downloadCenter.title"
        case downloadCenterURLPlaceholder = "downloadCenter.url.placeholder"
        case errorDetailsTechnical = "error.details.technical"
        case errorDetailsTitle = "error.details.title"
        case mediaAudioFormat = "media.audioFormat"
        case mediaBrowserCookies = "media.browserCookies"
        case mediaChooseOutputFolder = "media.chooseOutputFolder"
        case mediaCookiesChrome = "media.cookies.chrome"
        case mediaCookiesNone = "media.cookies.none"
        case mediaCookiesSafari = "media.cookies.safari"
        case mediaEditAndRetry = "media.editAndRetry"
        case mediaEditDownload = "media.editDownload"
        case mediaEmbedMetadata = "media.embedMetadata"
        case mediaEmbedThumbnail = "media.embedThumbnail"
        case mediaFolderSaveFailed = "media.folderSaveFailed"
        case mediaFormatAudioLabel = "media.format.audioLabel"
        case mediaFormatOriginal = "media.format.original"
        case mediaFormatUnknown = "media.format.unknown"
        case mediaFormatVideoLabel = "media.format.videoLabel"
        case mediaFormatVideoLabelWithNote = "media.format.videoLabelWithNote"
        case mediaHighestAvailable = "media.highestAvailable"
        case mediaMetadata = "media.metadata"
        case mediaOptionsTitle = "media.options.title"
        case mediaOutput = "media.output"
        case mediaOutputFolder = "media.outputFolder"
        case mediaOutputFormat = "media.outputFormat"
        case mediaReanalyze = "media.reanalyze"
        case mediaSelectedOutputFolder = "media.selectedOutputFolder"
        case mediaSubtitleDownload = "media.subtitle.download"
        case mediaSubtitleEmbed = "media.subtitle.embed"
        case mediaSubtitleLanguage = "media.subtitleLanguage"
        case mediaSubtitleMode = "media.subtitleMode"
        case mediaSubtitleNone = "media.subtitle.none"
        case mediaSubtitles = "media.subtitles"
        case mediaThumbnailUnavailable = "media.thumbnailUnavailable"
        case mediaUnavailableVideo = "media.unavailableVideo"
        case mediaUntitledPlaylist = "media.untitledPlaylist"
        case mediaUntitledVideo = "media.untitledVideo"
        case mediaVideoFormat = "media.videoFormat"
        case playlistClearSelection = "playlist.clearSelection"
        case playlistEntrySelect = "playlist.entry.select"
        case playlistEntryUnavailable = "playlist.entry.unavailable"
        case playlistEntryUnavailableNamed = "playlist.entry.unavailableNamed"
        case playlistSelectAll = "playlist.selectAll"
        case playlistSelectedCount = "playlist.selectedCount"
        case settingsAutomaticUpdates = "settings.automaticUpdates"
        case settingsConcurrentDownloads = "settings.concurrentDownloads"
        case settingsDefaultOptions = "settings.defaultOptions"
        case settingsDownloads = "settings.downloads"
        case settingsLanguage = "settings.language"
        case settingsLanguageEnglish = "settings.language.en"
        case settingsLanguageJapanese = "settings.language.ja"
        case settingsLanguageSystem = "settings.language.system"
        case settingsLanguageTraditionalChinese = "settings.language.zhHant"
        case settingsPreferences = "settings.preferences"
        case settingsSupport = "settings.support"
        case settingsData = "settings.data"
        case settingsSupportCreateReport = "settings.support.createReport"
        case settingsDataExport = "settings.data.export"
        case settingsDataManage = "settings.data.manage"
        case settingsUpdates = "settings.updates"
        case supportReportTitle = "supportReport.title"
        case supportReportNotice = "supportReport.notice"
        case supportReportSave = "supportReport.save"
        case supportReportDetails = "supportReport.details"
        case supportReportCategory = "supportReport.category"
        case supportReportSubject = "supportReport.subject"
        case supportReportMessage = "supportReport.message"
        case supportReportOptionalTitle = "supportReport.optional.title"
        case supportReportOptionalDescription = "supportReport.optional.description"
        case supportReportOptionalInclude = "supportReport.optional.include"
        case supportReportOptionalActivityWarning = "supportReport.optional.activityWarning"
        case supportReportPreviewTitle = "supportReport.preview.title"
        case supportReportPreviewDescription = "supportReport.preview.description"
        case supportReportPreviewFailed = "supportReport.preview.failed"
        case supportReportSavePrompt = "supportReport.savePrompt"
        case supportReportSaved = "supportReport.saved"
        case supportReportSaveFailed = "supportReport.saveFailed"
        case supportReportCategoryDownloadFailure = "supportReport.category.downloadFailure"
        case supportReportCategoryPrivacy = "supportReport.category.privacy"
        case supportReportCategorySecurity = "supportReport.category.security"
        case supportReportCategoryCopyright = "supportReport.category.copyright"
        case supportReportCategoryCancellation = "supportReport.category.cancellation"
        case supportReportCategoryIncorrectCharge = "supportReport.category.incorrectCharge"
        case supportReportCategoryAccountRecovery = "supportReport.category.accountRecovery"
        case supportReportCategoryGeneral = "supportReport.category.general"
        case supportReportFieldSourceURL = "supportReport.field.sourceURL"
        case supportReportFieldMediaTitle = "supportReport.field.mediaTitle"
        case supportReportFieldSelectedFormatID = "supportReport.field.selectedFormatID"
        case supportReportFieldDiagnosticExport = "supportReport.field.diagnosticExport"
        case supportReportFieldScreenshot = "supportReport.field.screenshot"
        case supportReportFieldContactEmail = "supportReport.field.contactEmail"
        case supportReportFieldMediaFile = "supportReport.field.mediaFile"
        case dataExportTitle = "dataExport.title"
        case dataExportNotice = "dataExport.notice"
        case dataExportPreviewTitle = "dataExport.preview.title"
        case dataExportSections = "dataExport.sections"
        case dataExportJobRecords = "dataExport.jobRecords"
        case dataExportThumbnailReferences = "dataExport.thumbnailReferences"
        case dataExportDiagnosticLines = "dataExport.diagnosticLines"
        case dataExportPreparing = "dataExport.preparing"
        case dataExportUnavailable = "dataExport.unavailable"
        case dataExportExclusions = "dataExport.exclusions"
        case dataExportReveal = "dataExport.reveal"
        case dataExportChooseAndExport = "dataExport.chooseAndExport"
        case dataExportPreviewFailed = "dataExport.previewFailed"
        case dataExportSaved = "dataExport.saved"
        case dataExportSaveFailed = "dataExport.saveFailed"
        case dataManagementTitle = "dataManagement.title"
        case dataManagementNotice = "dataManagement.notice"
        case dataManagementHistory = "dataManagement.history"
        case dataManagementAppData = "dataManagement.appData"
        case dataManagementDownloadedMedia = "dataManagement.downloadedMedia"
        case dataManagementSelectFileDescription = "dataManagement.selectFileDescription"
        case dataManagementChooseFile = "dataManagement.chooseFile"
        case dataManagementReviewFilePrompt = "dataManagement.reviewFilePrompt"
        case dataManagementActionCompleted = "dataManagement.actionCompleted"
        case dataManagementActionFailed = "dataManagement.actionFailed"
        case dataActionCompletedTitle = "dataAction.completed.title"
        case dataActionFailedTitle = "dataAction.failed.title"
        case dataActionDiagnosticsTitle = "dataAction.diagnostics.title"
        case dataActionResetSettingsTitle = "dataAction.resetSettings.title"
        case dataActionDeleteMediaTitle = "dataAction.deleteMedia.title"
        case dataActionClearHistoryButton = "dataAction.clearHistory.button"
        case dataActionClearDiagnosticsButton = "dataAction.clearDiagnostics.button"
        case dataActionResetSettingsButton = "dataAction.resetSettings.button"
        case dataActionDeleteFileButton = "dataAction.deleteFile.button"
        case dataActionCompletedConfirmation = "dataAction.completed.confirmation"
        case dataActionFailedConfirmation = "dataAction.failed.confirmation"
        case dataActionDiagnosticsConfirmation = "dataAction.diagnostics.confirmation"
        case dataActionResetSettingsConfirmation = "dataAction.resetSettings.confirmation"
        case dataActionDeleteMediaConfirmation = "dataAction.deleteMedia.confirmation"
        case dataActionNoFileSelected = "dataAction.noFileSelected"
        case dataActionHistoryRetained = "dataAction.history.retained"
        case dataActionDiagnosticsRetained = "dataAction.diagnostics.retained"
        case dataActionSettingsRetained = "dataAction.settings.retained"
        case dataActionMediaRetained = "dataAction.media.retained"
        case updateAvailableMessage = "update.available.message"
        case updateAvailableTitle = "update.available.title"
        case updateCheck = "update.check"
        case updateCheckAccessibility = "update.check.accessibility"
        case updateChecking = "update.checking"
        case updateDismiss = "update.dismiss"
        case updateFailedMessage = "update.failed.message"
        case updateFailedTitle = "update.failed.title"
        case updateOpenRelease = "update.openRelease"
        case updateUnsupportedMessage = "update.unsupported.message"
        case updateUnsupportedTitle = "update.unsupported.title"
        case updateUpToDateMessage = "update.upToDate.message"
        case updateUpToDateTitle = "update.upToDate.title"
    }

    static func string(_ key: Key, locale: Locale, _ arguments: CVarArg...) -> String {
        string(key.rawValue, locale: locale, arguments: arguments)
    }

    static func string(_ key: String, localeIdentifier: String) -> String {
        string(key, locale: Locale(identifier: localeIdentifier))
    }

    static func string(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        string(key, locale: locale, arguments: arguments)
    }

    private static func string(_ key: String, locale: Locale, arguments: [CVarArg]) -> String {
        let localeIdentifier = supportedIdentifier(for: locale)
        let format = catalog[key]?[localeIdentifier] ?? String(
            localized: String.LocalizationValue(key),
            table: "Localizable",
            bundle: .module,
            locale: locale
        )
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static let catalog: [String: [String: String]] = {
        let url = Bundle.main.url(forResource: "Localizable", withExtension: "xcstrings")
            ?? Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")
        guard let url,
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data) else {
            return [:]
        }
        return catalog.strings.mapValues { entry in
            entry.localizations.mapValues(\.stringUnit.value)
        }
    }()

    private static func supportedIdentifier(for locale: Locale) -> String {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if identifier.hasPrefix("zh-hant") || identifier.hasPrefix("zh-tw") || identifier.hasPrefix("zh-hk") {
            return "zh-Hant"
        }
        if identifier.hasPrefix("ja") { return "ja" }
        return "en"
    }
}

enum MediaFallbackText {
    static func localized(_ value: String, source: MediaTitleSource?, locale: Locale) -> String {
        let key: L10n.Key? = switch source {
        case .synthesizedUntitledVideo: .mediaUntitledVideo
        case .synthesizedUntitledPlaylist: .mediaUntitledPlaylist
        case .synthesizedUnavailableVideo: .mediaUnavailableVideo
        case .metadata, nil: nil
        }
        return key.map { L10n.string($0, locale: locale) } ?? value
    }
}

enum MediaFormatPresentation {
    static func label(for format: MediaFormat, locale: Locale) -> String {
        if format.audioCodec != nil, format.videoCodec == nil || format.videoCodec == "none" {
            let language = nonempty(format.language) ?? L10n.string(.mediaFormatOriginal, locale: locale)
            let note = nonempty(format.note) ?? L10n.string(.mediaFormatUnknown, locale: locale)
            let container = nonempty(format.container) ?? L10n.string(.mediaFormatUnknown, locale: locale)
            return L10n.string(.mediaFormatAudioLabel, locale: locale, language, note, container)
        }
        if let height = format.height {
            let container = nonempty(format.container) ?? L10n.string(.mediaFormatUnknown, locale: locale)
            if let note = nonempty(format.note) {
                return L10n.string(.mediaFormatVideoLabelWithNote, locale: locale, String(height), container, note)
            }
            return L10n.string(.mediaFormatVideoLabel, locale: locale, String(height), container)
        }
        return format.label
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private struct StringCatalog: Decodable {
    let strings: [String: StringCatalogEntry]
}

private struct StringCatalogEntry: Decodable {
    let localizations: [String: StringCatalogLocalization]
}

private struct StringCatalogLocalization: Decodable {
    let stringUnit: StringCatalogUnit
}

private struct StringCatalogUnit: Decodable {
    let value: String
}
