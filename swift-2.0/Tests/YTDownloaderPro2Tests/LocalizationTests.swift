import Foundation
import XCTest
@testable import YTDownloaderPro2

final class LocalizationTests: XCTestCase {
    private let localeIdentifiers = ["en", "ja", "zh-Hant"]
    private let maintainedRegionalMessages = [
        "Video is region restricted",
        "This video is restricted in your region",
        "The uploader has not made this video available in your country",
        "This video is not available in your country",
        "This video is geo-restricted"
    ]

    func testVisibleKeyInventoryIsExplicitAndComplete() {
        let expected: Set<String> = [
            "app.settings",
            "common.addSelected", "common.addToQueue", "common.cancel", "common.choose", "common.done", "common.save",
            "confirmation.cancelActive.message", "confirmation.cancelActive.title", "confirmation.cancelDownload.button",
            "confirmation.cancelDownloads.button", "confirmation.cancelMerging.message", "confirmation.cancelMerging.title",
            "confirmation.clearCompleted.button", "confirmation.clearCompleted.message", "confirmation.clearCompleted.title",
            "confirmation.removeRecord.button", "confirmation.removeRecord.message", "confirmation.removeRecord.title",
            "download.action.cancel", "download.action.edit", "download.action.editAndRetry", "download.action.errorDetails", "download.action.play",
            "download.action.reAdd", "download.action.removeRecord", "download.action.resume", "download.action.retry",
            "download.action.reveal", "download.action.startNow", "download.action.pause",
            "download.action.fileUnavailable", "download.action.playUnavailable", "download.action.revealUnavailable",
            "download.card.detail.eta", "download.card.detail.speed", "download.card.detail.transfer",
            "download.card.detail.transferEta", "download.card.detail.transferSpeed", "download.card.detail.transferSpeedEta",
            "download.card.format.mp3", "download.card.format.mp4", "download.card.progress", "download.card.unknown", "download.card.unknownSize",
            "download.status.analyzing", "download.status.cancelled", "download.status.completed", "download.status.downloading",
            "download.status.failed", "download.status.finishing", "download.status.paused", "download.status.queued",
            "downloadCenter.analyze", "downloadCenter.analyzing", "downloadCenter.empty", "downloadCenter.title",
            "downloadCenter.url.placeholder", "downloadCenter.bulk.cancel", "downloadCenter.bulk.clearCompleted",
            "downloadCenter.bulk.pause", "downloadCenter.bulk.resume", "downloadCenter.bulk.start",
            "downloadCenter.sidebar.all", "downloadCenter.sidebar.completed", "downloadCenter.sidebar.failed",
            "downloadCenter.sidebar.running", "downloadCenter.sidebar.stopped",
            "error.details.technical", "error.details.title",
            "media.audioFormat", "media.browserCookies", "media.chooseOutputFolder", "media.cookies.chrome",
            "media.cookies.none", "media.cookies.safari", "media.editAndRetry", "media.editDownload", "media.embedMetadata",
            "media.embedThumbnail", "media.folderSaveFailed", "media.highestAvailable", "media.options.title",
            "media.metadata", "media.output", "media.outputFolder", "media.outputFormat", "media.reanalyze", "media.selectedOutputFolder",
            "media.subtitleLanguage", "media.subtitleMode", "media.subtitles", "media.thumbnailUnavailable",
            "media.videoFormat", "media.subtitle.download", "media.subtitle.embed", "media.subtitle.none",
            "media.format.audioLabel", "media.format.original", "media.format.unknown", "media.format.videoLabel",
            "media.format.videoLabelWithNote", "media.unavailableVideo",
            "media.untitledPlaylist", "media.untitledVideo",
            "playlist.clearSelection", "playlist.entry.select", "playlist.entry.unavailable", "playlist.entry.unavailableNamed",
            "playlist.selectAll", "playlist.selectedCount",
            "settings.automaticUpdates", "settings.concurrentDownloads", "settings.defaultOptions", "settings.downloads",
            "settings.language", "settings.language.en", "settings.language.ja", "settings.language.system",
            "settings.language.zhHant", "settings.preferences", "settings.updates",
            "update.available.message", "update.available.title", "update.check", "update.check.accessibility",
            "update.checking", "update.dismiss", "update.failed.message", "update.failed.title",
            "update.openRelease", "update.unsupported.message", "update.unsupported.title",
            "update.upToDate.message", "update.upToDate.title"
        ]

        XCTAssertEqual(Set(L10n.Key.allCases.map(\.rawValue)), expected)
    }

    func testCatalogContainsEveryVisibleAndFailureKeyInEveryLocale() throws {
        let catalog = try loadCatalog()
        let expectedKeys = Set(L10n.Key.allCases.map(\.rawValue)).union(
            DownloadFailure.Category.allCases.flatMap { [$0.summaryKey, $0.recoveryKey] }
        )

        XCTAssertEqual(Set(catalog.strings.keys), expectedKeys)
        for key in expectedKeys {
            let entry = try XCTUnwrap(catalog.strings[key], "Missing key: \(key)")
            for locale in localeIdentifiers {
                let value = try XCTUnwrap(
                    entry.localizations[locale]?.stringUnit?.value,
                    "Missing \(locale) value for \(key)"
                )
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(locale) value for \(key)")
            }
        }
    }

    func testLocalizedPlaceholderSignaturesMatchEnglish() throws {
        let catalog = try loadCatalog()
        for (key, entry) in catalog.strings {
            let english = try XCTUnwrap(entry.localizations["en"]?.stringUnit?.value)
            let expected = placeholderSignature(in: english)
            for locale in localeIdentifiers where locale != "en" {
                let localized = try XCTUnwrap(entry.localizations[locale]?.stringUnit?.value)
                XCTAssertEqual(placeholderSignature(in: localized), expected, "Placeholder mismatch for \(key) in \(locale)")
            }
        }
    }

    func testLanguageOverrideSupportsSystemAndThreePersistedChoices() throws {
        let suiteName = "LocalizationTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: suite)

        for identifier in [nil, "zh-Hant", "en", "ja"] as [String?] {
            let settings = AppSettings(languageOverride: identifier)
            store.save(settings)
            XCTAssertEqual(store.load().languageOverride, identifier)
            XCTAssertEqual(settings.locale.identifier, identifier ?? Locale.current.identifier)
        }
    }

    func testUnsupportedPersistedLanguageFallsBackToSystem() {
        let settings = AppSettings(languageOverride: "fr")
        XCTAssertNil(settings.languageOverride)
        XCTAssertEqual(settings.locale.identifier, Locale.current.identifier)
    }

    func testClassifierDeterministicallyCoversRecoveryCategories() {
        let cases: [(String, DownloadFailure.Context, DownloadFailure.Category)] = [
            ("ERROR: Unsupported URL", .analysis, .invalidURL),
            ("This video is private", .analysis, .unavailableMedia),
            ("ERROR: The uploader has not made this video available in your country", .analysis, .unavailableMedia),
            ("Sign in to confirm your age", .analysis, .authenticationRequired),
            ("Unable to download webpage: The Internet connection appears to be offline", .download, .networkUnavailable),
            ("HTTP Error 403: Forbidden client validation failed", .download, .clientValidationFailed),
            ("bad CPU type in executable: yt-dlp_macos", .toolchain, .bundledDownloaderUnavailable),
            ("Permission denied while launching yt-dlp_macos", .toolchain, .bundledDownloaderUnavailable),
            ("ffmpeg is not installed", .toolchain, .bundledConverterUnavailable),
            ("Operation not permitted while writing output", .download, .outputPermissionDenied),
            ("No space left on device", .download, .diskFull),
            ("download exited with status 1", .download, .downloadFailed),
            ("conversion failed", .postProcessing, .postProcessingFailed),
            ("requested format is not available", .download, .formatReselectionRequired),
            ("downloads.json is corrupt", .persistence, .persistenceRecovery),
            ("metadata response was malformed", .analysis, .metadataUnavailable)
        ]

        for (stderr, context, expected) in cases {
            XCTAssertEqual(DownloadFailure.classify(stderr: stderr, context: context).category, expected, stderr)
        }
    }

    func testClassifierMatchesMaintainedRealWorldVariants() {
        let cases: [(String, DownloadFailure.Context, DownloadFailure.Category)] = [
            ("ERROR: 403: Forbidden", .download, .clientValidationFailed),
            ("ERROR: Video is unavailable", .analysis, .unavailableMedia),
            ("ERROR: Video is region restricted", .analysis, .unavailableMedia),
            ("ERROR: This video is restricted in your region", .analysis, .unavailableMedia),
            ("ERROR: [youtube] abc123: Video is region restricted", .download, .unavailableMedia),
            ("ERROR: [youtube] abc123: This video is restricted in your region", .download, .unavailableMedia),
            ("WARNING: Retrying metadata\nERROR: [youtube] abc123: This video is restricted in your region", .analysis, .unavailableMedia),
            ("ERROR: Requested format not available", .download, .formatReselectionRequired),
            ("urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed", .download, .networkUnavailable),
            ("socket.gaierror: Name or service not known", .download, .networkUnavailable),
            ("Temporary failure in name resolution", .download, .networkUnavailable),
            ("Network is unreachable", .download, .networkUnavailable),
            ("Connection reset by peer", .download, .networkUnavailable),
            ("Connection refused by server", .download, .networkUnavailable),
            ("Software caused connection aborted", .download, .networkUnavailable),
            ("Could not resolve host: www.youtube.com", .download, .networkUnavailable),
            ("getaddrinfo failed", .download, .networkUnavailable),
            ("Access denied while writing output", .download, .outputPermissionDenied),
            ("Access is denied while writing output", .download, .outputPermissionDenied)
        ]

        for (stderr, context, expected) in cases {
            XCTAssertEqual(DownloadFailure.classify(stderr: stderr, context: context).category, expected, stderr)
        }
    }

    func testClassifierDoesNotTreatOrdinaryTitlesOrOutputPathsAsFailurePhrases() {
        let cases: [(String, DownloadFailure.Context, DownloadFailure.Category)] = [
            ("Postprocessing failed while writing /Exports/Regional Highlights.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Network Connections.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Offline Collection.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Sign In.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Player Client.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Unsupported URL.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Private Video.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Login Required.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Requested Format Not Available.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Region Restricted.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Restricted in Your Region.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Access Denied.mp4", .postProcessing, .postProcessingFailed),
            ("Postprocessing failed while writing /Exports/Access Is Denied.mp4", .postProcessing, .postProcessingFailed),
            ("Metadata parser failed for Regional Highlights", .analysis, .metadataUnavailable),
            ("Metadata parser failed for Network Connections", .analysis, .metadataUnavailable),
            ("Metadata parser failed for Offline Collection", .analysis, .metadataUnavailable),
            ("Metadata parser failed for Region Restricted", .analysis, .metadataUnavailable),
            ("ERROR: Metadata parser failed for Restricted in Your Region", .analysis, .metadataUnavailable),
            ("[youtube] Region Restricted: Downloading webpage\nERROR: metadata response was malformed", .analysis, .metadataUnavailable),
            ("This Video Is Restricted in Your Region", .analysis, .metadataUnavailable),
            ("Download failed while writing /Exports/Region Restricted.mp4", .download, .downloadFailed),
            ("ERROR: Download failed while writing /Exports/Restricted in Your Region.mp4", .download, .downloadFailed),
            ("[download] Destination: /Exports/Restricted in Your Region.mp4\nERROR: download exited with status 1", .download, .downloadFailed),
            ("Video Is Region Restricted", .download, .downloadFailed)
        ]

        for (stderr, context, expected) in cases {
            XCTAssertEqual(DownloadFailure.classify(stderr: stderr, context: context).category, expected, stderr)
        }
    }

    func testEveryMaintainedRegionalPhraseRequiresAnErrorDiagnosticInAnalysisAndDownload() {
        for message in maintainedRegionalMessages {
            XCTAssertEqual(
                DownloadFailure.classify(stderr: "  ERROR: \(message)?!  ", context: .analysis).category,
                .unavailableMedia,
                "analysis diagnostic: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(stderr: "\tERROR: \(message).", context: .download).category,
                .unavailableMedia,
                "download diagnostic: \(message)"
            )

            XCTAssertEqual(
                DownloadFailure.classify(stderr: message, context: .analysis).category,
                .metadataUnavailable,
                "bare analysis text: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(stderr: message, context: .download).category,
                .downloadFailed,
                "bare download text: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "ERROR: Metadata parser failed for \(message)",
                    context: .analysis
                ).category,
                .metadataUnavailable,
                "analysis title: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "ERROR: Download failed while writing /Exports/\(message).mp4",
                    context: .download
                ).category,
                .downloadFailed,
                "download path: \(message)"
            )
        }
    }

    func testEveryMaintainedRegionalPhraseSupportsBothMaintainedExtractorPrefixes() {
        for message in maintainedRegionalMessages {
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "ERROR: [youtube] AbC_123-XY: \(message)",
                    context: .analysis
                ).category,
                .unavailableMedia,
                "youtube prefix: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "ERROR: [youtube:tab] PL_abc-123: \(message)!",
                    context: .download
                ).category,
                .unavailableMedia,
                "youtube:tab prefix: \(message)"
            )
        }
    }

    func testEveryMaintainedRegionalPhraseRejectsEmptyAndMalformedExtractorPrefixes() {
        for message in maintainedRegionalMessages {
            let analysisLookalikes = [
                "ERROR: [youtube] : \(message)",
                "ERROR: [youtube] abc/123: \(message)",
                "ERROR: [youtube] abc 123: \(message)",
                "ERROR: [youtube] abc123 \(message)",
                "ERROR: [youtube abc123: \(message)"
            ]
            let downloadLookalikes = [
                "ERROR: [youtube:tab] : \(message)",
                "ERROR: [youtube:tab] PL/123: \(message)",
                "ERROR: [youtube:tab] PL 123: \(message)",
                "ERROR: [youtube:tab]PL123: \(message)",
                "ERROR: [youtube:playlist] PL123: \(message)"
            ]

            for stderr in analysisLookalikes {
                XCTAssertEqual(
                    DownloadFailure.classify(stderr: stderr, context: .analysis).category,
                    .metadataUnavailable,
                    stderr
                )
            }
            for stderr in downloadLookalikes {
                XCTAssertEqual(
                    DownloadFailure.classify(stderr: stderr, context: .download).category,
                    .downloadFailed,
                    stderr
                )
            }
        }
    }

    func testEveryMaintainedRegionalPhraseRejectsLeadingPunctuationAndEmbeddedErrorMarkers() {
        for message in maintainedRegionalMessages {
            let analysisLookalikes = [
                "ERROR: .\(message)",
                "ERROR: !!!\(message)",
                "WARNING: ERROR: \(message)"
            ]
            let downloadLookalikes = [
                "ERROR: ?\(message)",
                "ERROR: ...\(message)",
                "trace ERROR: \(message)"
            ]

            for stderr in analysisLookalikes {
                XCTAssertEqual(
                    DownloadFailure.classify(stderr: stderr, context: .analysis).category,
                    .metadataUnavailable,
                    stderr
                )
            }
            for stderr in downloadLookalikes {
                XCTAssertEqual(
                    DownloadFailure.classify(stderr: stderr, context: .download).category,
                    .downloadFailed,
                    stderr
                )
            }
        }
    }

    func testRegionalDiagnosticsHandleMixedCaseLFAndCRLFWithoutMatchingMultilineLookalikes() {
        for message in maintainedRegionalMessages {
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "WARNING: retrying\r\n  ErRoR: [YoUtUbE] AbC_123-X: \(message.uppercased())?!\r\ntrace: done",
                    context: .analysis
                ).category,
                .unavailableMedia,
                "CRLF diagnostic: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "WARNING: retrying\nERROR: [YOUTUBE:TAB] PL_ABC-123: \(message.uppercased()).\ntrace: done",
                    context: .download
                ).category,
                .unavailableMedia,
                "LF diagnostic: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "WARNING: retrying\r\nMetadata parser failed for \(message.uppercased())\r\nERROR: metadata response malformed",
                    context: .analysis
                ).category,
                .metadataUnavailable,
                "CRLF title: \(message)"
            )
            XCTAssertEqual(
                DownloadFailure.classify(
                    stderr: "[download] Destination: /Exports/\(message.uppercased()).mp4\r\nERROR: download exited with status 1",
                    context: .download
                ).category,
                .downloadFailed,
                "CRLF path: \(message)"
            )
        }
    }

    func testRegionalDiagnosticPreservesClassifierPrecedenceAndContextGates() {
        let cases: [(String, DownloadFailure.Context, DownloadFailure.Category)] = [
            ("ERROR: Video is region restricted\nNo space left on device", .download, .diskFull),
            ("ERROR: This video is geo-restricted\nAccess denied while writing output", .download, .outputPermissionDenied),
            ("ERROR: Unsupported URL\nERROR: This video is not available in your country", .analysis, .invalidURL),
            ("Sign in to confirm\nERROR: Video is region restricted", .analysis, .authenticationRequired),
            ("ERROR: Video is region restricted\nNetwork is unreachable", .download, .unavailableMedia),
            ("ERROR: Video is region restricted\nERROR: 403: Forbidden", .download, .unavailableMedia),
            ("ERROR: Video is region restricted\nRequested format not available", .download, .unavailableMedia),
            ("ERROR: Video is region restricted", .postProcessing, .postProcessingFailed),
            ("ERROR: Video is region restricted", .persistence, .persistenceRecovery),
            ("ERROR: Video is region restricted", .toolchain, .bundledDownloaderUnavailable),
            ("ERROR: Video is region restricted\nffmpeg is unavailable", .toolchain, .bundledConverterUnavailable)
        ]

        for (stderr, context, expected) in cases {
            XCTAssertEqual(DownloadFailure.classify(stderr: stderr, context: context).category, expected, stderr)
        }
    }

    func testUserRecoveryNeverContainsRawHelperOutputSecretsOrInternalToolNames() {
        let stderr = "ffmpeg is not installed authorization: Bearer secret-token"
        let failure = DownloadFailure.classify(stderr: stderr, context: .toolchain)

        for locale in localeIdentifiers {
            let summary = failure.userSummary(locale: locale)
            let recovery = failure.userRecoverySuggestion(locale: locale)
            let primaryText = "\(summary) \(recovery)".lowercased()
            XCTAssertFalse(primaryText.contains(stderr.lowercased()))
            XCTAssertFalse(primaryText.contains("secret-token"))
            XCTAssertFalse(primaryText.contains("ffmpeg"))
            XCTAssertFalse(primaryText.contains("yt-dlp"))
        }
        XCTAssertEqual(failure.technicalDetail, "ffmpeg is not installed authorization: [REDACTED]")
    }

    func testDownloadCardPresentationUsesTheActiveLocale() {
        let presentation = DownloadCardPresentation(job: .fixture(status: .downloading, outputKind: .mp3))

        XCTAssertEqual(presentation.statusLabel(locale: Locale(identifier: "en")), "Downloading")
        XCTAssertEqual(presentation.statusLabel(locale: Locale(identifier: "zh-Hant")), "下載中")
        XCTAssertEqual(presentation.statusLabel(locale: Locale(identifier: "ja")), "ダウンロード中")
        XCTAssertEqual(presentation.formatSummary(locale: Locale(identifier: "ja")), "MP3 オーディオ")
    }

    func testConfirmationAndAccessibilityCopyUseTheActiveLocale() {
        let locale = Locale(identifier: "zh-Hant")
        let missing = DownloadCardPresentation(
            job: .fixture(status: .completed, outputURL: URL(fileURLWithPath: "/definitely/missing.mp4"))
        )

        XCTAssertEqual(DownloadConfirmation.removeRecord.title(locale: locale), "要移除此記錄嗎？")
        XCTAssertEqual(missing.help(for: .play, locale: locale), "無法播放：檔案遺失或不是一般檔案")
        XCTAssertEqual(
            missing.accessibilityLabel(for: .revealInFinder, locale: locale),
            "在 Finder 中顯示，因檔案遺失或不是一般檔案而無法使用"
        )
    }

    func testOutputFolderStateUsesTheActiveLocale() {
        let state = DownloadOptionsViewState(options: .defaults, locale: Locale(identifier: "ja"))
        XCTAssertEqual(state.outputFolderLabel, "保存先フォルダを選択")
    }

    func testOnlyExplicitlySynthesizedFallbackTitlesSwitchLocale() {
        let japanese = Locale(identifier: "ja")
        let cases: [(String, MediaTitleSource, String)] = [
            ("Untitled video", .synthesizedUntitledVideo, "タイトルなしの動画"),
            ("Untitled playlist", .synthesizedUntitledPlaylist, "タイトルなしの再生リスト"),
            ("Unavailable video", .synthesizedUnavailableVideo, "利用できない動画")
        ]

        for (title, source, localized) in cases {
            XCTAssertEqual(MediaFallbackText.localized(title, source: source, locale: japanese), localized)
            XCTAssertEqual(MediaFallbackText.localized(title, source: .metadata, locale: japanese), title)
            XCTAssertEqual(MediaFallbackText.localized(title, source: nil, locale: japanese), title)
        }
    }

    func testGeneratedFormatLabelsSwitchLocale() {
        let japanese = Locale(identifier: "ja")
        let audio = MediaFormat(
            id: "140",
            label: "legacy label",
            audioCodec: "mp4a",
            container: nil,
            language: nil,
            note: nil
        )
        let video = MediaFormat(
            id: "137",
            label: "legacy label",
            videoCodec: "avc1",
            container: "mp4",
            height: 1080,
            note: "60fps"
        )

        XCTAssertEqual(MediaFormatPresentation.label(for: audio, locale: japanese), "オーディオ：オリジナル（不明）- 不明")
        XCTAssertEqual(MediaFormatPresentation.label(for: video, locale: japanese), "1080p - mp4（60fps）")
    }

    private func loadCatalog() throws -> Catalog {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("Sources/YTDownloaderPro2/Resources/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func placeholderSignature(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@|f)"#)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }.sorted()
    }

}

private struct Catalog: Decodable {
    let strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    let localizations: [String: CatalogLocalization]
}

private struct CatalogLocalization: Decodable {
    let stringUnit: CatalogStringUnit?
}

private struct CatalogStringUnit: Decodable {
    let value: String
}
