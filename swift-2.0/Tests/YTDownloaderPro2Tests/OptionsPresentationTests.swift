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
            videoFormats: [
                format(id: "video-high", label: "2160p", videoCodec: "avc1.640033", container: "mp4"),
                format(id: "video-low", label: "720p", videoCodec: "avc1.4d401f", container: "mp4")
            ],
            audioFormats: [
                format(id: "audio-high", label: "AAC 256 kbps", audioCodec: "mp4a.40.2", container: "m4a"),
                format(id: "audio-low", label: "AAC 128 kbps", audioCodec: "mp4a.40.2", container: "m4a")
            ]
        )

        let model = MediaOptionsPresentation(analysis: analysis, defaults: .defaults)

        XCTAssertEqual(model.selectedVideoID, "video-high")
        XCTAssertEqual(model.selectedAudioID, "audio-high")
        XCTAssertEqual(model.options.videoQuality, .format(id: "video-high", label: "2160p"))
        XCTAssertEqual(model.options.audioQuality, .format(id: "audio-high", label: "AAC 256 kbps"))
        XCTAssertEqual(model.options.selectedVideoFormat, analysis.videoFormats.first.map(PersistedFormatPresentation.init))
        XCTAssertEqual(model.options.selectedAudioFormat, analysis.audioFormats.first.map(PersistedFormatPresentation.init))
    }

    func testVideoOptionsExposeDynamicSubtitlesAndReplaceUnavailablePersistedSelection() {
        let tracks = [
            SubtitleTrack(languageCode: "en-official", displayName: "English", source: .official),
            SubtitleTrack(languageCode: "zh-Hant-official", displayName: "Traditional Chinese", source: .official),
            SubtitleTrack(languageCode: "ja", displayName: "Japanese", source: .automatic)
        ]
        var analysis = videoAnalysis(videoFormats: [], audioFormats: [])
        analysis.subtitleTracks = tracks
        let defaults = DownloadOptions(
            subtitleMode: .download,
            subtitleLanguage: "missing-language",
            subtitleSource: .official
        )

        let model = MediaOptionsPresentation(analysis: analysis, defaults: defaults)

        XCTAssertEqual(model.subtitleChoices, tracks)
        XCTAssertEqual(model.options.subtitleMode, .download)
        XCTAssertEqual(model.options.subtitleLanguage, "en-official")
        XCTAssertEqual(model.options.subtitleSource, .official)
    }

    func testVideoWithoutSubtitlesDisablesPersistedSubtitleRequest() {
        let defaults = DownloadOptions(
            subtitleMode: .download,
            subtitleLanguage: "ja",
            subtitleSource: .automatic
        )

        let model = MediaOptionsPresentation(
            analysis: videoAnalysis(videoFormats: [], audioFormats: []),
            defaults: defaults
        )

        XCTAssertEqual(model.subtitleChoices, [])
        XCTAssertEqual(model.options.subtitleMode, .none)
        XCTAssertNil(model.options.subtitleLanguage)
        XCTAssertNil(model.options.subtitleSource)
    }

    func testMockFreeDefaultsToHighestQuickTimeCompatibleVideoAtOrBelow720p() {
        let analysis = videoAnalysis(videoFormats: [
            format(id: "2160", label: "2160p", videoCodec: "avc1", container: "mp4", height: 2160),
            format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080),
            format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
        ], audioFormats: [])

        let model = MediaOptionsPresentation(
            analysis: analysis,
            defaults: .defaults,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )

        XCTAssertEqual(model.videoChoices.map(\.id), ["2160", "1080", "720"])
        XCTAssertEqual(model.selectedVideoID, "720")
    }

    func testMockFreePreservesExplicitHighVideoSelectionForStructuredDenial() {
        let high = format(
            id: "1080",
            label: "1080p",
            videoCodec: "avc1",
            container: "mp4",
            height: 1080
        )
        let low = format(
            id: "720",
            label: "720p",
            videoCodec: "avc1",
            container: "mp4",
            height: 720
        )
        let policy = FeaturePolicyContext.enforced(.init(snapshot: .syntheticFree))
        let defaults = DownloadOptions(
            videoQuality: .format(id: high.id, label: high.label),
            selectedVideoFormat: PersistedFormatPresentation(high)
        )

        let model = MediaOptionsPresentation(
            analysis: videoAnalysis(videoFormats: [high, low], audioFormats: []),
            defaults: defaults,
            featurePolicy: policy
        )

        XCTAssertEqual(model.selectedVideoID, "1080")
        XCTAssertEqual(
            model.decisionForSelectedOptions(in: policy).denial?.reason,
            .videoHeightRequiresPro
        )
    }

    func testPublicCompatibilityStillDefaultsToHighestCompatibleVideo() {
        let analysis = videoAnalysis(videoFormats: [
            format(id: "2160", label: "2160p", videoCodec: "avc1", container: "mp4", height: 2160),
            format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
        ], audioFormats: [])

        XCTAssertEqual(
            MediaOptionsPresentation(analysis: analysis, defaults: .defaults).selectedVideoID,
            "2160"
        )
    }

    func testSelectedVideoDecisionUsesStructuredHeightAndMP3RemainsAllowed() {
        let policy = FeaturePolicyContext.enforced(.init(snapshot: .syntheticFree))
        let analysis = videoAnalysis(videoFormats: [
            format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080),
            format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
        ], audioFormats: [])
        var videoModel = MediaOptionsPresentation(
            analysis: analysis,
            defaults: .defaults,
            featurePolicy: policy
        )
        videoModel.selectVideo("1080")

        XCTAssertEqual(
            videoModel.decisionForSelectedOptions(in: policy).denial?.reason,
            .videoHeightRequiresPro
        )

        let audioModel = MediaOptionsPresentation(
            analysis: analysis,
            defaults: DownloadOptions(outputKind: .mp3),
            featurePolicy: policy
        )
        XCTAssertEqual(audioModel.decisionForSelectedOptions(in: policy), .allowed)
    }

    func testFreeVideoFormatAccessLocksOnlyAnalyzedProQualitiesAndDefaultsToHighestEligibleChoice() {
        let formats = [
            format(id: "source", label: "Source", videoCodec: "avc1", container: "mp4", note: "source"),
            format(id: "1440", label: "1440p", videoCodec: "avc1", container: "mp4", height: 1440),
            format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080),
            format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720),
            format(id: "480", label: "480p", videoCodec: "avc1", container: "mp4", height: 480),
            format(id: "unknown", label: "Unknown", videoCodec: "avc1", container: "mp4")
        ]

        let presentation = VideoFormatMenuPresentation(
            formats: formats,
            selectedID: nil,
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )

        XCTAssertEqual(presentation.accesses.map(\.format.id), formats.map(\.id))
        XCTAssertEqual(presentation.selectedID, "720")
        XCTAssertEqual(presentation.accesses.map(\.denial?.reason), [
            .sourceQualityRequiresPro,
            .videoHeightRequiresPro,
            .videoHeightRequiresPro,
            nil,
            nil,
            .unknownVideoHeight
        ])
    }

    func testFourKHeightAndSourceResolutionUseUHDPolicyWhileTestProUnlocksEveryActualChoice() {
        let formats = [
            format(id: "2160", label: "2160p", videoCodec: "avc1", container: "mp4", height: 2160),
            format(id: "resolution-source", label: "Original", videoCodec: "avc1", container: "mp4", resolution: "4K source"),
            format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
        ]
        let free = VideoFormatMenuPresentation(
            formats: formats,
            selectedID: nil,
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )
        let pro = VideoFormatMenuPresentation(
            formats: formats,
            selectedID: nil,
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticPro))
        )

        XCTAssertEqual(free.accesses.compactMap(\.denial?.reason), [
            .sourceQualityRequiresPro,
            .sourceQualityRequiresPro
        ])
        XCTAssertTrue(pro.accesses.allSatisfy(\.isAllowed))
        XCTAssertEqual(pro.selectedID, "2160")
    }

    func testMP3PresentationDoesNotApplyVideoHeightLocks() {
        let presentation = VideoFormatMenuPresentation(
            formats: [
                format(id: "2160", label: "2160p", videoCodec: "avc1", container: "mp4", height: 2160),
                format(id: "unknown", label: "Unknown", videoCodec: "avc1", container: "mp4")
            ],
            selectedID: nil,
            outputKind: .mp3,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )

        XCTAssertTrue(presentation.accesses.allSatisfy(\.isAllowed))
        XCTAssertEqual(presentation.selectedID, "2160")
    }

    func testLockedActivationPreservesSelectionAndEmitsOnlySanitizedDenial() throws {
        let presentation = VideoFormatMenuPresentation(
            formats: [
                format(id: "1080", label: "Private title https://youtu.be/private", videoCodec: "avc1", container: "mp4", height: 1080),
                format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
            ],
            selectedID: "720",
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )
        let locked = try XCTUnwrap(presentation.accesses.first)
        var selectedID = presentation.selectedID
        var emittedDenial: FeatureDenial?

        VideoFormatMenuInteraction.activate(
            locked,
            onSelect: { selectedID = $0 },
            onRequestUpgrade: { emittedDenial = $0 }
        )

        XCTAssertEqual(selectedID, "720")
        XCTAssertEqual(emittedDenial?.requiredFeature, .videoHD)
        XCTAssertEqual(emittedDenial?.reason, .videoHeightRequiresPro)
        XCTAssertTrue(emittedDenial?.canChooseFreeAlternative == true)
        XCTAssertFalse(String(describing: emittedDenial).contains("youtu.be"))
        XCTAssertFalse(String(describing: emittedDenial).contains("Private title"))
    }

    func testAllowedActivationUsesTheSameSelectableActionForKeyboardAndPointer() throws {
        let presentation = VideoFormatMenuPresentation(
            formats: [format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)],
            selectedID: nil,
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )
        let allowed = try XCTUnwrap(presentation.accesses.first)
        var selectedID: String?
        var upgradeRequestCount = 0

        VideoFormatMenuInteraction.activate(
            allowed,
            onSelect: { selectedID = $0 },
            onRequestUpgrade: { _ in upgradeRequestCount += 1 }
        )

        XCTAssertEqual(selectedID, "720")
        XCTAssertEqual(upgradeRequestCount, 0)
        XCTAssertEqual(
            allowed.accessibilityLabel(locale: Locale(identifier: "en")),
            "720p - mp4"
        )
    }

    func testDowngradeReconciliationSelectsHighestAllowedFormatOnlyOnce() {
        let formats = [
            format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1_080),
            format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720),
            format(id: "480", label: "480p", videoCodec: "avc1", container: "mp4", height: 480)
        ]
        let downgraded = VideoFormatMenuPresentation(
            formats: formats,
            selectedID: "1080",
            outputKind: .mp4,
            featurePolicy: AppPlan.free.featurePolicyContext
        ).selectionReconciliation()

        XCTAssertEqual(downgraded, VideoFormatSelectionReconciliation(selectedID: "720", didNormalize: true))

        let alreadyNormalized = VideoFormatMenuPresentation(
            formats: formats,
            selectedID: downgraded.selectedID,
            outputKind: .mp4,
            featurePolicy: AppPlan.free.featurePolicyContext
        ).selectionReconciliation()

        XCTAssertEqual(alreadyNormalized, VideoFormatSelectionReconciliation(selectedID: "720", didNormalize: false))
    }

    func testLockedAccessibilityLabelIncludesQualityAndProRequirement() throws {
        let presentation = VideoFormatMenuPresentation(
            formats: [format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080)],
            selectedID: nil,
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )
        let locked = try XCTUnwrap(presentation.accesses.first)
        let label = locked.accessibilityLabel(locale: Locale(identifier: "en"))

        XCTAssertTrue(label.contains("1080p - mp4"))
        XCTAssertTrue(label.contains("Pro"))
    }

    func testVideoFormatMenuLeadingIndicatorDistinguishesSelectionLockAndAvailableRows() throws {
        let presentation = VideoFormatMenuPresentation(
            formats: [
                format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080),
                format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720),
                format(id: "480", label: "480p", videoCodec: "avc1", container: "mp4", height: 480)
            ],
            selectedID: "720",
            outputKind: .mp4,
            featurePolicy: .enforced(.init(snapshot: .syntheticFree))
        )

        let locked = try XCTUnwrap(presentation.accesses.first(where: { $0.id == "1080" }))
        let selected = try XCTUnwrap(presentation.accesses.first(where: { $0.id == "720" }))
        let available = try XCTUnwrap(presentation.accesses.first(where: { $0.id == "480" }))

        XCTAssertEqual(locked.leadingSystemImage(isSelected: false), "lock.fill")
        XCTAssertEqual(selected.leadingSystemImage(isSelected: true), "checkmark")
        XCTAssertNil(available.leadingSystemImage(isSelected: false))
        XCTAssertEqual(locked.leadingSystemImage(isSelected: true), "checkmark")
    }

    func testOutputModeNoticeIsConservativeAndHiddenForMP3() {
        var options = DownloadOptions.defaults
        options.mp4OutputMode = .originalEncoding
        XCTAssertEqual(DownloadOptionsViewState(options: options).mp4ModeNotice, .mediaMP4OriginalNotice)
        options.mp4OutputMode = .quickTimeCompatible
        XCTAssertEqual(DownloadOptionsViewState(options: options).mp4ModeNotice, .mediaMP4ConversionNotice)
        options.selectVideoFormat(format(id: "137", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080))
        options.selectAudioFormat(MediaFormat(id: "140", label: "AAC", audioCodec: "mp4a", container: "m4a"))
        XCTAssertNil(DownloadOptionsViewState(options: options).mp4ModeNotice)
        options.selectVideoFormat(format(id: "313", label: "2160p", videoCodec: "vp9", container: "webm", height: 2160))
        XCTAssertEqual(DownloadOptionsViewState(options: options).mp4ModeNotice, .mediaMP4ConversionNotice)
        options.selectOutputKind(.mp3)
        XCTAssertNil(DownloadOptionsViewState(options: options).mp4ModeNotice)
        XCTAssertEqual(options.mp4OutputMode, .quickTimeCompatible)
        XCTAssertEqual(options.normalizedForExecution().mp4OutputMode, .quickTimeCompatible)
    }

    func testMP4DefaultsPreserveHighestSourceEvenWhenConversionIsNeeded() {
        let vp9 = MediaFormat(
            id: "248",
            label: "1080p - webm",
            codec: "vp9",
            videoCodec: "vp9",
            audioCodec: nil,
            container: "webm",
            width: 1920,
            height: 1080,
            resolution: "1920x1080",
            framesPerSecond: 30,
            bitrate: 2_000,
            language: nil,
            estimatedFileSize: nil,
            note: "1080p"
        )
        let avc = MediaFormat(
            id: "137",
            label: "1080p - mp4",
            codec: "avc1.640028",
            videoCodec: "avc1.640028",
            audioCodec: nil,
            container: "mp4",
            width: 1920,
            height: 1080,
            resolution: "1920x1080",
            framesPerSecond: 30,
            bitrate: 1_800,
            language: nil,
            estimatedFileSize: nil,
            note: "1080p"
        )
        let opus = MediaFormat(
            id: "251",
            label: "Audio: original (medium) - webm",
            codec: "opus",
            videoCodec: nil,
            audioCodec: "opus",
            container: "webm",
            width: nil,
            height: nil,
            resolution: nil,
            framesPerSecond: nil,
            bitrate: 160,
            language: nil,
            estimatedFileSize: nil,
            note: "medium"
        )
        let aac = MediaFormat(
            id: "140",
            label: "Audio: original (medium) - m4a",
            codec: "mp4a.40.2",
            videoCodec: nil,
            audioCodec: "mp4a.40.2",
            container: "m4a",
            width: nil,
            height: nil,
            resolution: nil,
            framesPerSecond: nil,
            bitrate: 128,
            language: nil,
            estimatedFileSize: nil,
            note: "medium"
        )

        let model = MediaOptionsPresentation(
            analysis: videoAnalysis(videoFormats: [vp9, avc], audioFormats: [opus, aac]),
            defaults: .defaults
        )

        XCTAssertEqual(model.selectedVideoID, "248")
        XCTAssertEqual(model.selectedAudioID, "251")
        XCTAssertEqual(model.videoChoices.map(\.id), ["248", "137"])
        XCTAssertEqual(model.audioChoices.map(\.id), ["251", "140"])
    }

    func test4KSourceFormatsRemainVisibleWhileFreeSelectionStaysAt720p() {
        let formats = [
            format(id: "313", label: "2160p VP9", videoCodec: "vp9", container: "webm", height: 2160),
            format(id: "401", label: "2160p AV1", videoCodec: "av01", container: "mp4", height: 2160),
            format(id: "136", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
        ]
        let analysis = videoAnalysis(videoFormats: formats, audioFormats: [])
        let freePolicy = FeaturePolicyContext.enforced(.init(snapshot: .syntheticFree))
        let free = MediaOptionsPresentation(analysis: analysis, defaults: .defaults, featurePolicy: freePolicy)
        let pro = MediaOptionsPresentation(analysis: analysis, defaults: .defaults,
                                         featurePolicy: .enforced(.init(snapshot: .syntheticPro)))
        XCTAssertEqual(free.videoChoices.map(\.id), ["313", "401", "136"])
        XCTAssertEqual(free.selectedVideoID, "136")
        XCTAssertEqual(pro.selectedVideoID, "313")
        let menu = VideoFormatMenuPresentation(formats: free.videoChoices, selectedID: free.selectedVideoID,
                                               outputKind: .mp4, featurePolicy: freePolicy)
        XCTAssertEqual(menu.accesses[0].leadingSystemImage(isSelected: false), "lock.fill")
        XCTAssertEqual(menu.accesses[1].leadingSystemImage(isSelected: false), "lock.fill")
    }

    func testPersistedStructuredFormatChoicesRelocalizeWithoutReanalysis() throws {
        let video = MediaFormat(
            id: "137",
            label: "1080p - mp4 (60fps)",
            videoCodec: "avc1",
            container: "mp4",
            height: 1080,
            note: "60fps"
        )
        let audio = MediaFormat(
            id: "140",
            label: "Audio: original (medium) - m4a",
            audioCodec: "mp4a",
            container: "m4a",
            language: nil,
            note: "medium"
        )
        let options = DownloadOptions(
            videoQuality: .format(id: video.id, label: video.label),
            audioQuality: .format(id: audio.id, label: audio.label),
            selectedVideoFormat: PersistedFormatPresentation(video),
            selectedAudioFormat: PersistedFormatPresentation(audio)
        )

        let encoded = try JSONEncoder().encode(options)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains(video.label))
        XCTAssertFalse(encodedText.contains(audio.label))

        let restored = try JSONDecoder().decode(DownloadOptions.self, from: encoded)
        let presentation = MediaOptionsPresentation(options: restored)
        let restoredVideo = try XCTUnwrap(presentation.videoChoices.first)
        let restoredAudio = try XCTUnwrap(presentation.audioChoices.first)

        XCTAssertEqual(MediaFormatPresentation.label(for: restoredVideo, locale: Locale(identifier: "en")), "1080p - mp4 (60fps)")
        XCTAssertEqual(MediaFormatPresentation.label(for: restoredVideo, locale: Locale(identifier: "ja")), "1080p - mp4（60fps）")
        XCTAssertEqual(MediaFormatPresentation.label(for: restoredAudio, locale: Locale(identifier: "zh-Hant")), "音訊：原始語言（medium）- m4a")
        XCTAssertEqual(MediaFormatPresentation.label(for: restoredAudio, locale: Locale(identifier: "ja")), "オーディオ：オリジナル（medium）- m4a")
    }

    func testLegacyEnglishFormatLabelsMigrateToStructuredPresentationOnDecode() throws {
        let options = DownloadOptions(
            videoQuality: .format(id: "137", label: "1080p - mp4 (60fps)"),
            audioQuality: .format(id: "140", label: "Audio: original (medium) - m4a")
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "selectedVideoFormat")
        legacyObject.removeValue(forKey: "selectedAudioFormat")
        legacyObject["videoQuality"] = [
            "format": ["id": "137", "label": "1080p - mp4 (60fps)"]
        ]
        legacyObject["audioQuality"] = [
            "format": ["id": "140", "label": "Audio: original (medium) - m4a"]
        ]

        let restored = try JSONDecoder().decode(
            DownloadOptions.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        let presentation = MediaOptionsPresentation(options: restored)

        XCTAssertEqual(restored.selectedVideoFormat?.height, 1080)
        XCTAssertEqual(restored.selectedVideoFormat?.container, "mp4")
        XCTAssertEqual(restored.selectedVideoFormat?.note, "60fps")
        XCTAssertEqual(restored.selectedAudioFormat?.audioCodec, "legacy-audio")
        XCTAssertEqual(restored.selectedAudioFormat?.container, "m4a")
        XCTAssertEqual(restored.selectedAudioFormat?.note, "medium")
        XCTAssertEqual(
            MediaFormatPresentation.label(for: try XCTUnwrap(presentation.videoChoices.first), locale: Locale(identifier: "ja")),
            "1080p - mp4（60fps）"
        )
        XCTAssertEqual(
            MediaFormatPresentation.label(for: try XCTUnwrap(presentation.audioChoices.first), locale: Locale(identifier: "zh-Hant")),
            "音訊：原始語言（medium）- m4a"
        )
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
        var analysis = videoAnalysis(
            videoFormats: [format(id: "video-high", label: "2160p"), format(id: "video-low", label: "720p")],
            audioFormats: [format(id: "audio-high", label: "Opus 160 kbps"), format(id: "audio-low", label: "AAC 128 kbps")]
        )
        analysis.subtitleTracks = [
            SubtitleTrack(languageCode: "ja", displayName: "Japanese", source: .official)
        ]
        let model = MediaOptionsPresentation(analysis: analysis, defaults: defaults)

        XCTAssertEqual(model.selectedVideoID, "video-low")
        XCTAssertEqual(model.selectedAudioID, "audio-low")
        XCTAssertEqual(model.options.outputKind, .mp3)
        XCTAssertEqual(model.options.subtitleMode, .download)
        XCTAssertEqual(model.options.subtitleLanguage, "ja")
        XCTAssertEqual(model.options.subtitleSource, .official)
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
        XCTAssertNil(
            DownloadCenterCommandRouter.route(
                .commandV,
                focus: .nonEditable,
                selectedJob: nil,
                clipboard: "https://media-user:media-password@www.youtube.com/watch?v=video123"
            )
        )
        XCTAssertEqual(
            DownloadCenterCommandRouter.route(
                .commandV,
                focus: .nonEditable,
                selectedJob: nil,
                clipboard: "https://youtu.be/one\nhttps://youtu.be/two"
            ),
            .placeClipboardURL("https://youtu.be/one https://youtu.be/two")
        )
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

    private func format(
        id: String,
        label: String,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        container: String? = nil,
        height: Int? = nil,
        resolution: String? = nil,
        note: String? = nil
    ) -> MediaFormat {
        MediaFormat(
            id: id,
            label: label,
            codec: nil,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            container: container,
            width: nil,
            height: height,
            resolution: resolution,
            framesPerSecond: nil,
            bitrate: nil,
            language: nil,
            estimatedFileSize: nil,
            note: note
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
