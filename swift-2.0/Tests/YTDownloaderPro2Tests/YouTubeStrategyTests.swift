import Foundation
import XCTest
@testable import YTDownloaderPro2

final class YouTubeStrategyTests: XCTestCase {
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
            "bestvideo*+bestaudio/best",
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
            "--js-runtimes",
            "quickjs:/bundle/qjs",
            "--extractor-args",
            "youtube:player_client=web_embedded",
            "https://example.com/video"
        ])
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

        let arguments = strategy.downloadArguments(job: job, toolchain: .fixture(), attempt: 0)

        XCTAssertTrue(arguments.contains("--write-subs"))
        XCTAssertEqual(argument(after: "--sub-langs", in: arguments), "ja")
        XCTAssertFalse(arguments.contains("--embed-subs"))
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
