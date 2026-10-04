import Foundation
import XCTest
@testable import YTDownloaderPro2

final class YouTubeStrategyTests: XCTestCase {
    func testBothOutputModesKeepExactIDsAndCapEveryFreeVideoBranch() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        for mode in [MP4OutputMode.quickTimeCompatible, .originalEncoding] {
            for (videoID, audioID, expected) in [
                (nil, nil, "bestvideo+bestaudio/best"),
                ("313", nil, "313+bestaudio"),
                (nil, "251", "bestvideo+251"),
                ("401", "251", "401+251")
            ] as [(String?, String?, String)] {
                var job = DownloadJob.fixture()
                job.options.mp4OutputMode = mode
                job.options.videoQuality = videoID.map { .format(id: $0, label: "2160p") } ?? .best
                job.options.audioQuality = audioID.map { .format(id: $0, label: "Opus") } ?? .best
                let pro = strategy.downloadArguments(job: job, toolchain: .fixture(), attempt: 0)
                XCTAssertEqual(argument(after: "--format", in: pro), expected)
                let free = strategy.downloadArguments(job: job, toolchain: .fixture(), attempt: 0, featurePolicy: AppPlan.free.featurePolicyContext)
                let capped = expected.split(separator: "/").map { branch in
                    var streams = branch.split(separator: "+").map(String.init)
                    streams[0] += "[height<=720]"
                    return streams.joined(separator: "+")
                }.joined(separator: "/")
                XCTAssertEqual(argument(after: "--format", in: free), capped)
            }
        }
    }

    func testDownloadUsesPersistedClientButFreshAnalysisStillComparesBoth() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        var job = DownloadJob.fixture()
        for client in [YouTubeClientStrategy.webEmbedded, .defaultClient] {
            job.options.clientStrategy = client
            for attempt in [0, 1] {
                let arguments = strategy.downloadArguments(job: job, toolchain: .fixture(), attempt: attempt)
                XCTAssertEqual(arguments.contains("--extractor-args"), client == .webEmbedded)
                XCTAssertFalse(arguments.contains("--cookies-from-browser"))
            }
            let first = strategy.analysisArguments(url: job.sourceURL, options: job.options, attempt: 0)
            let second = strategy.analysisArguments(url: job.sourceURL, options: job.options, attempt: 1)
            XCTAssertTrue(first.contains("--extractor-args"))
            XCTAssertFalse(second.contains("--extractor-args"))
        }
    }

    func testAnalysisArgumentsUseQuickJSVerifiedClientAndNoTLSBypass() {
        let strategy = YouTubeStrategy(toolchain: .fixture())

        let arguments = strategy.analysisArguments(
            url: "https://youtu.be/example",
            options: .defaults,
            attempt: 0
        )

        XCTAssertEqual(arguments, [
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            "--js-runtimes",
            "quickjs:/tmp/qjs",
            "--extractor-args",
            "youtube:player_client=web_embedded",
            "https://youtu.be/example"
        ])
        XCTAssertFalse(arguments.contains("--no-check-certificate"))
        XCTAssertFalse(arguments.joined(separator: " ").localizedCaseInsensitiveContains("po_token"))
    }

    func testCookiesAreAddedOnlyForExplicitSupportedBrowserSelection() {
        let strategy = YouTubeStrategy(toolchain: .fixture())

        let withoutCookies = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 0)
        let chromeCookies = strategy.analysisArguments(
            url: "https://youtu.be/example",
            options: .fixture(cookies: .chrome),
            attempt: 0
        )
        let safariCookies = strategy.analysisArguments(
            url: "https://youtu.be/example",
            options: .fixture(cookies: .safari),
            attempt: 0
        )

        XCTAssertFalse(withoutCookies.contains("--cookies-from-browser"))
        XCTAssertEqual(argument(after: "--cookies-from-browser", in: chromeCookies), "chrome")
        XCTAssertEqual(argument(after: "--cookies-from-browser", in: safariCookies), "safari")
    }

    func testUncookiedSecondAttemptUsesBundledDefaultWithoutExtractorArguments() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let first = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 0)
        let fallback = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 1)
        let outOfRange = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 99)

        XCTAssertEqual(argument(after: "--extractor-args", in: first), "youtube:player_client=web_embedded")
        XCTAssertEqual(fallback, [
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            "--js-runtimes",
            "quickjs:/tmp/qjs",
            "https://youtu.be/example"
        ])
        XCTAssertEqual(outOfRange, fallback)
        XCTAssertEqual(strategy.maximumAttempts(for: .defaults), 2)
        XCTAssertFalse(fallback.contains("--extractor-args"))
        XCTAssertFalse(fallback.joined(separator: " ").localizedCaseInsensitiveContains("po_token"))
    }

    func testBrowserCookieSelectionUsesOneWebEmbeddedAttemptOnly() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let chromeOptions = DownloadOptions.fixture(cookies: .chrome)
        let initial = strategy.analysisArguments(url: "https://youtu.be/example", options: chromeOptions, attempt: 0)
        let outOfRange = strategy.analysisArguments(url: "https://youtu.be/example", options: chromeOptions, attempt: 1)

        XCTAssertEqual(argument(after: "--extractor-args", in: initial), "youtube:player_client=web_embedded")
        XCTAssertEqual(outOfRange, initial)
        XCTAssertEqual(strategy.maximumAttempts(for: chromeOptions), 1)
    }

    func testUncookiedDownloadSecondAttemptUsesBundledDefaultWithoutExtractorArguments() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let arguments = strategy.downloadArguments(job: .fixture(), toolchain: .fixture(), attempt: 1)

        XCTAssertFalse(arguments.contains("--extractor-args"))
        XCTAssertFalse(arguments.joined(separator: " ").localizedCaseInsensitiveContains("android_vr"))
    }

    func testMP4DownloadArgumentsUsePassedToolchainAndExactStructuredTemplates() {
        let strategy = YouTubeStrategy(toolchain: .fixture(qjs: URL(fileURLWithPath: "/strategy/qjs")))
        let downloadToolchain = Toolchain.fixture(
            ffmpeg: URL(fileURLWithPath: "/bundle/ffmpeg"),
            qjs: URL(fileURLWithPath: "/bundle/qjs")
        )
        let job = DownloadJob.fixture(outputURL: URL(fileURLWithPath: "/tmp/Downloads/Example video.mp4"))

        let arguments = strategy.downloadArguments(job: job, toolchain: downloadToolchain, attempt: 0)

        XCTAssertEqual(arguments, [
            "--no-warnings",
            "--continue",
            "--no-overwrites",
            "--progress",
            "--newline",
            "--ffmpeg-location",
            "/bundle",
            "--format",
            "bestvideo+bestaudio/best",
            "--output",
            "/tmp/Downloads/Example video.%(ext)s",
            "--print",
            "before_dl:ytdp:phase|downloading",
            "--progress-template",
            "download:ytdp:progress|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template",
            "postprocess:ytdp:phase|merging",
            "--print",
            "after_move:ytdp:filepath|%(filepath)s",
            "--merge-output-format",
            "mp4",
            "--remux-video",
            "mp4",
            "--js-runtimes",
            "quickjs:/bundle/qjs",
            "--extractor-args",
            "youtube:player_client=web_embedded",
            "https://example.com/video"
        ])
    }

    func testMP4DownloadPreservesExplicitWebMSelections() {
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
        var job = DownloadJob.fixture(outputKind: .mp4)
        job.options.selectVideoFormat(vp9)
        job.options.selectAudioFormat(opus)

        let arguments = YouTubeStrategy(toolchain: .fixture()).downloadArguments(
            job: job,
            toolchain: .fixture(),
            attempt: 0
        )

        XCTAssertEqual(
            argument(after: "--format", in: arguments),
            "248+251"
        )
    }

    func testMP3DownloadArgumentsUsePostprocessingPhaseAndSelectedAudioFormat() {
        let strategy = YouTubeStrategy(toolchain: .fixture(qjs: URL(fileURLWithPath: "/strategy/qjs")))
        let downloadToolchain = Toolchain.fixture(
            ffmpeg: URL(fileURLWithPath: "/bundle/ffmpeg"),
            qjs: URL(fileURLWithPath: "/bundle/qjs")
        )
        var audioJob = DownloadJob.fixture(
            outputKind: .mp3,
            outputURL: URL(fileURLWithPath: "/tmp/Downloads/Audio.mp3")
        )
        audioJob.options.audioQuality = .format(id: "251", label: "160 kbps")

        let audioArguments = strategy.downloadArguments(job: audioJob, toolchain: downloadToolchain, attempt: 0)

        XCTAssertEqual(audioArguments, [
            "--no-warnings",
            "--continue",
            "--no-overwrites",
            "--progress",
            "--newline",
            "--ffmpeg-location",
            "/bundle",
            "--format",
            "251",
            "--output",
            "/tmp/Downloads/Audio.%(ext)s",
            "--print",
            "before_dl:ytdp:phase|downloading",
            "--progress-template",
            "download:ytdp:progress|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template",
            "postprocess:ytdp:phase|postprocessing",
            "--print",
            "after_move:ytdp:filepath|%(filepath)s",
            "--extract-audio",
            "--audio-format",
            "mp3",
            "--js-runtimes",
            "quickjs:/bundle/qjs",
            "--extractor-args",
            "youtube:player_client=web_embedded",
            "https://example.com/video"
        ])
    }

    func testPersistedMP3EmbedSubtitleSelectionNeverEmitsEmbedSubs() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        var job = DownloadJob.fixture(outputKind: .mp3)
        job.options.subtitleMode = .embed
        job.options.subtitleLanguage = "ja"
        job.options.subtitleSource = .official

        let arguments = strategy.downloadArguments(job: job, toolchain: .fixture(), attempt: 0)

        XCTAssertTrue(arguments.contains("--write-subs"))
        XCTAssertEqual(argument(after: "--sub-langs", in: arguments), "ja")
        XCTAssertEqual(argument(after: "--sub-format", in: arguments), "srt")
        XCTAssertFalse(arguments.contains("--embed-subs"))
    }

    func testOfficialSubtitleSelectionDownloadsOnlyTheExactOfficialTrackAsSRT() {
        var job = DownloadJob.fixture()
        job.options.subtitleMode = .download
        job.options.subtitleLanguage = "zh-Hant-official"
        job.options.subtitleSource = .official

        let arguments = YouTubeStrategy(toolchain: .fixture()).downloadArguments(
            job: job,
            toolchain: .fixture(),
            attempt: 0
        )

        XCTAssertTrue(arguments.contains("--write-subs"))
        XCTAssertFalse(arguments.contains("--write-auto-subs"))
        XCTAssertEqual(argument(after: "--sub-langs", in: arguments), "zh-Hant-official")
        XCTAssertEqual(argument(after: "--sub-format", in: arguments), "srt")
    }

    func testAutomaticSubtitleSelectionDownloadsOnlyTheExactAutomaticTrackAsSRT() {
        var job = DownloadJob.fixture()
        job.options.subtitleMode = .download
        job.options.subtitleLanguage = "ja"
        job.options.subtitleSource = .automatic

        let arguments = YouTubeStrategy(toolchain: .fixture()).downloadArguments(
            job: job,
            toolchain: .fixture(),
            attempt: 0
        )

        XCTAssertFalse(arguments.contains("--write-subs"))
        XCTAssertTrue(arguments.contains("--write-auto-subs"))
        XCTAssertEqual(argument(after: "--sub-langs", in: arguments), "ja")
        XCTAssertEqual(argument(after: "--sub-format", in: arguments), "srt")
    }

    func testSubtitleModeWithoutASelectedTrackDoesNotFallBackToLiveChat() {
        var job = DownloadJob.fixture()
        job.options.subtitleMode = .download
        job.options.subtitleLanguage = nil
        job.options.subtitleSource = nil

        let arguments = YouTubeStrategy(toolchain: .fixture()).downloadArguments(
            job: job,
            toolchain: .fixture(),
            attempt: 0
        )

        XCTAssertFalse(arguments.contains("--write-subs"))
        XCTAssertFalse(arguments.contains("--write-auto-subs"))
        XCTAssertFalse(arguments.contains("--sub-langs"))
        XCTAssertFalse(arguments.contains("--sub-format"))
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
