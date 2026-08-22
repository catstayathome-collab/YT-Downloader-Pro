import XCTest
@testable import YTDownloaderPro2

final class OptionsPresentationTests: XCTestCase {
    func testVideoOptionsRetainAnalyzedIdentityForCompactSheetHeader() {
        let thumbnailURL = URL(string: "https://images.test/video.jpg")!
        let analysis = VideoAnalysis(
            sourceURL: "https://www.youtube.com/watch?v=video123",
            title: "A deliberately long analyzed title that must remain available to the sheet header",
            duration: 125,
            thumbnailURL: thumbnailURL,
            videoFormats: [format(id: "video-high", label: "2160p")],
            audioFormats: [format(id: "audio-high", label: "Opus 160 kbps")]
        )

        let model = MediaOptionsPresentation(analysis: analysis, defaults: .defaults)

        XCTAssertEqual(model.identity?.title, analysis.title)
        XCTAssertEqual(model.identity?.durationText, "2:05")
        XCTAssertEqual(model.identity?.thumbnail, .remote(thumbnailURL))
        XCTAssertGreaterThanOrEqual(model.identity?.titleLineLimit ?? 0, 3)
    }

    func testVideoIdentityUsesSafeThumbnailFallback() {
        let model = MediaOptionsPresentation(
            analysis: videoAnalysis(videoFormats: [], audioFormats: []),
            defaults: .defaults
        )

        XCTAssertEqual(model.identity?.thumbnail, .fallback)
    }

    func testVideoOptionsDefaultToHighestAvailableVideoAndAudio() {
        let analysis = videoAnalysis(
            videoFormats: [format(id: "video-high", label: "2160p"), format(id: "video-low", label: "720p")],
            audioFormats: [format(id: "audio-high", label: "Opus 160 kbps"), format(id: "audio-low", label: "AAC 128 kbps")]
        )

        let model = MediaOptionsPresentation(analysis: analysis, defaults: .defaults)

        XCTAssertEqual(model.selectedVideoID, "video-high")
        XCTAssertEqual(model.selectedAudioID, "audio-high")
        XCTAssertEqual(model.options.videoQuality, .format(id: "video-high", label: "2160p"))
        XCTAssertEqual(model.options.audioQuality, .format(id: "audio-high", label: "Opus 160 kbps"))
    }

    func testVideoOptionsPreserveSupportedDefaultChoicesAndExposeAllOutputOptions() {
        let defaults = DownloadOptions(
            outputKind: .mp3,
            videoQuality: .format(id: "video-low", label: "720p"),
            audioQuality: .format(id: "audio-low", label: "AAC 128 kbps"),
            subtitleMode: .embed,
            subtitleLanguage: "ja",
            embedThumbnail: true,
            embedMetadata: true,
            cookies: .safari,
            outputDirectoryBookmark: Data("bookmark".utf8),
            outputDirectoryDisplayPath: "/tmp/Downloads"
        )
        let model = MediaOptionsPresentation(
            analysis: videoAnalysis(
                videoFormats: [format(id: "video-high", label: "2160p"), format(id: "video-low", label: "720p")],
                audioFormats: [format(id: "audio-high", label: "Opus 160 kbps"), format(id: "audio-low", label: "AAC 128 kbps")]
            ),
            defaults: defaults
        )

        XCTAssertEqual(model.selectedVideoID, "video-low")
        XCTAssertEqual(model.selectedAudioID, "audio-low")
        XCTAssertEqual(model.options.outputKind, .mp3)
        XCTAssertEqual(model.options.subtitleMode, .download)
        XCTAssertEqual(model.options.subtitleLanguage, "ja")
        XCTAssertTrue(model.options.embedThumbnail)
        XCTAssertTrue(model.options.embedMetadata)
        XCTAssertEqual(model.options.cookies, .safari)
        XCTAssertEqual(model.options.outputDirectoryDisplayPath, "/tmp/Downloads")
    }

    func testFreshOptionsRequireDurableOutputFolderBeforeQueueing() {
        let state = DownloadOptionsViewState(options: .defaults)

        XCTAssertFalse(state.canSubmit)
        XCTAssertEqual(state.outputFolderLabel, "Choose output folder")
    }

    func testSavedOptionsWithBookmarkRemainReadyAndKeepTheirFolderLabel() {
        let options = DownloadOptions(
            outputDirectoryBookmark: Data("durable-bookmark".utf8),
            outputDirectoryDisplayPath: "/Users/example/Downloads"
        )

        let state = DownloadOptionsViewState(options: options)

        XCTAssertTrue(state.canSubmit)
        XCTAssertEqual(state.outputFolderLabel, "/Users/example/Downloads")
    }

    func testMP3HidesEmbedSubtitleModeAndNormalizesExistingEmbedSelectionToSidecar() {
        var options = DownloadOptions(outputKind: .mp4, subtitleMode: .embed)

        options.selectOutputKind(.mp3)
        let state = DownloadOptionsViewState(options: options)

        XCTAssertEqual(options.subtitleMode, .download)
        XCTAssertEqual(state.availableSubtitleModes, [.none, .download])
        XCTAssertFalse(state.availableSubtitleModes.contains(.embed))
    }

    func testResponderClassificationKeepsEditableTextNativeThenPrioritizesPlaylistOverControls() {
        XCTAssertEqual(
            DownloadCenterFocusClassifier.classify(
                .init(
                    urlFieldIsFocused: false,
                    playlistSelectionIsPresented: true,
                    modalSheetIsPresented: true,
                    responderIsEditableText: true,
                    responderIsControl: true
                )
            ),
            .editableText
        )
        XCTAssertEqual(
            DownloadCenterFocusClassifier.classify(
                .init(
                    urlFieldIsFocused: false,
                    playlistSelectionIsPresented: true,
                    modalSheetIsPresented: true,
                    responderIsEditableText: false,
                    responderIsControl: true
                )
            ),
            .playlistSelectionSheet
        )
        XCTAssertEqual(
            DownloadCenterFocusClassifier.classify(
                .init(
                    urlFieldIsFocused: false,
                    playlistSelectionIsPresented: false,
                    modalSheetIsPresented: false,
                    responderIsEditableText: false,
                    responderIsControl: true
                )
            ),
            .interactiveControl
        )
    }

    func testPlaylistStartsWithEveryAvailableEntrySelectedAndCommandAReselectsOnlyAvailableEntries() {
        let analysis = PlaylistAnalysis(
            id: "playlist",
            title: "Playlist",
            entries: [
                playlistEntry(id: "available-1", isAvailable: true),
                playlistEntry(id: "private", isAvailable: false),
                playlistEntry(id: "available-2", isAvailable: true)
            ]
        )
        var model = PlaylistSelectionPresentation(analysis: analysis)

        XCTAssertEqual(model.selectedIDs, ["available-1", "available-2"])
        model.clearSelection()
        model.selectAll()

        XCTAssertEqual(model.selectedIDs, ["available-1", "available-2"])
    }

    func testKeyboardRoutingRequiresNonEditableFocusForJobCommands() {
        let downloading = DownloadJob.fixture(status: .downloading)
        let paused = DownloadJob.fixture(status: .paused)

        XCTAssertEqual(
            DownloadCenterCommandRouter.route(.space, focus: .nonEditable, selectedJob: downloading, clipboard: nil),
            .toggleSelectedJob(downloading.id)
        )
        XCTAssertEqual(
            DownloadCenterCommandRouter.route(.space, focus: .nonEditable, selectedJob: paused, clipboard: nil),
            .toggleSelectedJob(paused.id)
        )
        XCTAssertNil(DownloadCenterCommandRouter.route(.space, focus: .editableText, selectedJob: downloading, clipboard: nil))
        XCTAssertNil(DownloadCenterCommandRouter.route(.space, focus: .interactiveControl, selectedJob: downloading, clipboard: nil))
        XCTAssertNil(DownloadCenterCommandRouter.route(.space, focus: .modalSheet, selectedJob: downloading, clipboard: nil))
        XCTAssertNil(DownloadCenterCommandRouter.route(.space, focus: .nonEditable, selectedJob: .fixture(status: .queued), clipboard: nil))
    }

    func testKeyboardRoutingLimitsEnterDeleteCommandAAndClipboardRoutingToLegalContexts() {
        let completed = DownloadJob.fixture(status: .completed)

        XCTAssertEqual(
            DownloadCenterCommandRouter.route(.enter, focus: .permanentURLField, selectedJob: nil, clipboard: nil),
            .analyzePermanentURL
        )
        XCTAssertNil(DownloadCenterCommandRouter.route(.enter, focus: .editableText, selectedJob: nil, clipboard: nil))
        XCTAssertEqual(
            DownloadCenterCommandRouter.route(.delete, focus: .nonEditable, selectedJob: completed, clipboard: nil),
            .requestRecordRemoval(completed.id)
        )
        XCTAssertNil(DownloadCenterCommandRouter.route(.delete, focus: .nonEditable, selectedJob: .fixture(status: .paused), clipboard: nil))
        XCTAssertEqual(
            DownloadCenterCommandRouter.route(.commandA, focus: .playlistSelectionSheet, selectedJob: nil, clipboard: nil),
            .selectAllPlaylistEntries
        )
        XCTAssertNil(DownloadCenterCommandRouter.route(.commandA, focus: .nonEditable, selectedJob: nil, clipboard: nil))
        XCTAssertEqual(
            DownloadCenterCommandRouter.route(
                .commandV,
                focus: .nonEditable,
                selectedJob: nil,
                clipboard: "https://www.youtube.com/watch?v=video123"
            ),
            .placeClipboardURL("https://www.youtube.com/watch?v=video123")
        )
        XCTAssertNil(
            DownloadCenterCommandRouter.route(
                .commandV,
                focus: .editableText,
                selectedJob: nil,
                clipboard: "https://www.youtube.com/watch?v=video123"
            )
        )
        XCTAssertNil(
            DownloadCenterCommandRouter.route(
                .commandV,
                focus: .modalSheet,
                selectedJob: nil,
                clipboard: "https://www.youtube.com/watch?v=video123"
            )
        )
        XCTAssertNil(DownloadCenterCommandRouter.route(.commandV, focus: .nonEditable, selectedJob: nil, clipboard: "not a URL"))
    }

    private func videoAnalysis(videoFormats: [MediaFormat], audioFormats: [MediaFormat]) -> VideoAnalysis {
        VideoAnalysis(
            sourceURL: "https://www.youtube.com/watch?v=video123",
            title: "Example video",
            duration: 120,
            thumbnailURL: nil,
            videoFormats: videoFormats,
            audioFormats: audioFormats
        )
    }

    private func format(id: String, label: String) -> MediaFormat {
        MediaFormat(
            id: id,
            label: label,
            codec: nil,
            videoCodec: nil,
            audioCodec: nil,
            container: nil,
            width: nil,
            height: nil,
            resolution: nil,
            framesPerSecond: nil,
            bitrate: nil,
            language: nil,
            estimatedFileSize: nil
        )
    }

    private func playlistEntry(id: String, isAvailable: Bool) -> PlaylistEntry {
        PlaylistEntry(
            id: id,
            sourceURL: "https://www.youtube.com/watch?v=\(id)",
            title: id,
            duration: nil,
            thumbnailURL: nil,
            isAvailable: isAvailable
        )
    }
}
