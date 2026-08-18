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

    func testUncookiedFallbackUsesBoundedTVClientWithoutPromisingFormatQuality() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let first = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 0)
        let fallback = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 1)
        let outOfRange = strategy.analysisArguments(url: "https://youtu.be/example", options: .defaults, attempt: 99)

        XCTAssertEqual(argument(after: "--extractor-args", in: first), "youtube:player_client=web_embedded")
        XCTAssertEqual(argument(after: "--extractor-args", in: fallback), "youtube:player_client=tv")
        XCTAssertEqual(outOfRange, fallback)
        XCTAssertEqual(strategy.maximumAttempts(for: .defaults), 2)
        XCTAssertFalse(fallback.joined(separator: " ").localizedCaseInsensitiveContains("po_token"))
    }

    func testBrowserCookieSelectionDoesNotUseTVFallbackBecauseItsCookieCapabilityIsUnsafe() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let chromeOptions = DownloadOptions.fixture(cookies: .chrome)
        let initial = strategy.analysisArguments(url: "https://youtu.be/example", options: chromeOptions, attempt: 0)
        let outOfRange = strategy.analysisArguments(url: "https://youtu.be/example", options: chromeOptions, attempt: 1)

        XCTAssertEqual(argument(after: "--extractor-args", in: initial), "youtube:player_client=web_embedded")
        XCTAssertEqual(outOfRange, initial)
        XCTAssertEqual(strategy.maximumAttempts(for: chromeOptions), 1)
    }

    func testDownloadArgumentsUseBundledFFmpegContinuationAndBestVideoAudioDefaults() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let job = DownloadJob.fixture(outputURL: URL(fileURLWithPath: "/tmp/Downloads/Example video.mp4"))

        let arguments = strategy.downloadArguments(job: job, toolchain: .fixture(), attempt: 0)

        XCTAssertEqual(argument(after: "--ffmpeg-location", in: arguments), "/tmp")
        XCTAssertEqual(argument(after: "--format", in: arguments), "bestvideo*+bestaudio/best")
        XCTAssertEqual(argument(after: "--output", in: arguments), "/tmp/Downloads/Example video.%(ext)s")
        XCTAssertTrue(arguments.contains("--continue"))
        XCTAssertTrue(arguments.contains("--no-overwrites"))
        XCTAssertTrue(arguments.contains("--progress-template"))
        XCTAssertTrue(arguments.contains("--print"))
    }

    func testDownloadArgumentsUseSelectedFormatIDsAndMP3Conversion() {
        let strategy = YouTubeStrategy(toolchain: .fixture())
        let videoJob = DownloadJob.fixture(
            outputURL: URL(fileURLWithPath: "/tmp/Downloads/Selected.mp4")
        )
        var selectedVideoJob = videoJob
        selectedVideoJob.options = DownloadOptions(
            outputKind: .mp4,
            videoQuality: .format(id: "137", label: "1080p"),
            audioQuality: .format(id: "140", label: "128 kbps")
        )
        var audioJob = DownloadJob.fixture(
            outputKind: .mp3,
            outputURL: URL(fileURLWithPath: "/tmp/Downloads/Audio.mp3")
        )
        audioJob.options.audioQuality = .format(id: "251", label: "160 kbps")

        let selectedVideoArguments = strategy.downloadArguments(job: selectedVideoJob, toolchain: .fixture(), attempt: 0)
        let audioArguments = strategy.downloadArguments(job: audioJob, toolchain: .fixture(), attempt: 0)

        XCTAssertEqual(argument(after: "--format", in: selectedVideoArguments), "137+140")
        XCTAssertEqual(argument(after: "--format", in: audioArguments), "251")
        XCTAssertTrue(audioArguments.contains("--extract-audio"))
        XCTAssertEqual(argument(after: "--audio-format", in: audioArguments), "mp3")
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
