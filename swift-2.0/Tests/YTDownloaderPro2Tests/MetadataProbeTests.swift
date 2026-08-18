import Foundation
import XCTest
@testable import YTDownloaderPro2

final class MetadataProbeTests: XCTestCase {
    func testVideoFixtureDecodingDeduplicatesFormatsAndPreservesQualityMetadata() async throws {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 0, stdout: try fixtureText(named: "video-analysis.json"), stderr: "")
        ])
        let result = try await MetadataProbe(toolchain: .fixture(), processRunner: runner).analyze(
            url: "https://www.youtube.com/watch?v=video123",
            options: .defaults
        )

        guard case let .video(video) = result else {
            return XCTFail("Expected video analysis")
        }
        XCTAssertEqual(video.title, "Deterministic Video")
        XCTAssertEqual(video.duration, 123.5)
        XCTAssertEqual(video.videoFormats.map(\.id), ["137", "hls-1080", "136"])
        XCTAssertEqual(video.audioFormats.map(\.id), ["251", "140"])
        XCTAssertEqual(video.videoFormats.first?.container, "mp4")
        XCTAssertEqual(video.videoFormats.first?.videoCodec, "avc1.640028")
        XCTAssertEqual(video.videoFormats.first?.width, 1920)
        XCTAssertEqual(video.videoFormats.first?.height, 1080)
        XCTAssertEqual(video.videoFormats.first?.framesPerSecond, 60)
        XCTAssertEqual(video.videoFormats.first?.bitrate, 4500)
        XCTAssertEqual(video.videoFormats.first?.estimatedFileSize, 123_456_789)
        XCTAssertEqual(video.videoFormats[1].container, "mp4")
        XCTAssertEqual(video.videoFormats[1].height, 1080)
        XCTAssertFalse(video.videoFormats.map(\.id).contains("drm-2160"))
        XCTAssertFalse(video.videoFormats.map(\.id).contains("missing-url"))
        XCTAssertEqual(video.audioFormats.first?.audioCodec, "opus")
        XCTAssertEqual(video.audioFormats.last?.language, "en")
        XCTAssertEqual(video.audioFormats.last?.estimatedFileSize, 5_678_901)
        XCTAssertFalse(video.audioFormats.map(\.id).contains("drm-audio"))
    }

    func testPlaylistFixturePreservesSourceOrderAndUnavailableEntryIdentity() async throws {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 0, stdout: try fixtureText(named: "playlist-analysis.json"), stderr: "")
        ])
        let result = try await MetadataProbe(toolchain: .fixture(), processRunner: runner).analyze(
            url: "https://www.youtube.com/playlist?list=playlist123",
            options: .defaults
        )

        guard case let .playlist(playlist) = result else {
            return XCTFail("Expected playlist analysis")
        }
        XCTAssertEqual(playlist.id, "playlist123")
        XCTAssertEqual(playlist.entries.map(\.id), ["first001", "gone002", "third003"])
        XCTAssertEqual(playlist.entries.map(\.sourceURL), [
            "https://www.youtube.com/watch?v=first001",
            "https://www.youtube.com/watch?v=gone002",
            "https://www.youtube.com/watch?v=third003"
        ])
        XCTAssertEqual(playlist.entries.map(\.isAvailable), [true, false, true])
        XCTAssertEqual(playlist.entries[1].unavailabilityReason, "private")
    }

    func testMalformedJSONBecomesSanitizedMetadataFailureWithoutRetry() async {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 0, stdout: "{not-json", stderr: "raw-stderr-secret")
        ])

        await assertFailure(
            from: MetadataProbe(toolchain: .fixture(), processRunner: runner),
            url: "https://youtu.be/example",
            category: .metadataUnavailable
        )
        let commandCount = await runner.commandCount()
        XCTAssertEqual(commandCount, 1)
    }

    func testNonzeroProcessResultBecomesSanitizedStableFailure() async {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 1, stdout: "raw-stdout-secret", stderr: "Requested format is not available")
        ])

        await assertFailure(
            from: MetadataProbe(toolchain: .fixture(), processRunner: runner),
            url: "https://youtu.be/example",
            category: .unavailableMedia
        )
        let commandCount = await runner.commandCount()
        XCTAssertEqual(commandCount, 1)
    }

    func testRetryUsesFallbackOnlyFor403ClientFailure() async throws {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 1, stdout: "", stderr: "HTTP Error 403: Forbidden"),
            .init(exitCode: 0, stdout: try fixtureText(named: "video-analysis.json"), stderr: "")
        ])

        _ = try await MetadataProbe(toolchain: .fixture(), processRunner: runner).analyze(
            url: "https://youtu.be/example",
            options: .defaults
        )

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(argument(after: "--extractor-args", in: commands[0]), "youtube:player_client=web_embedded")
        XCTAssertFalse(commands[1].arguments.contains("--extractor-args"))
    }

    func testRetryStopsAtReviewedFallbackBound() async {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 1, stdout: "", stderr: "HTTP Error 403: Forbidden"),
            .init(exitCode: 1, stdout: "", stderr: "HTTP Error 403: Forbidden")
        ])

        await assertFailure(
            from: MetadataProbe(toolchain: .fixture(), processRunner: runner),
            url: "https://youtu.be/example",
            category: .authenticationRequired
        )
        let commandCount = await runner.commandCount()
        XCTAssertEqual(commandCount, 2)
    }

    func testRetryWithBrowserCookiesStopsAfterWebEmbeddedAttempt() async {
        let runner = AnalysisProcessRunner(results: [
            .init(exitCode: 1, stdout: "", stderr: "HTTP Error 403: Forbidden")
        ])
        let probe = MetadataProbe(toolchain: .fixture(), processRunner: runner)

        do {
            _ = try await probe.analyze(url: "https://youtu.be/example", options: .fixture(cookies: .chrome))
            XCTFail("Expected authentication failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .authenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(argument(after: "--extractor-args", in: commands[0]), "youtube:player_client=web_embedded")
    }

    func testInvalidURLDoesNotStartAProcessOrRetry() async {
        let runner = AnalysisProcessRunner(results: [])

        await assertFailure(
            from: MetadataProbe(toolchain: .fixture(), processRunner: runner),
            url: "not a URL",
            category: .invalidURL
        )
        let commandCount = await runner.commandCount()
        XCTAssertEqual(commandCount, 0)
    }

    private func assertFailure(
        from probe: MetadataProbe,
        url: String,
        category: DownloadFailure.Category
    ) async {
        do {
            _ = try await probe.analyze(url: url, options: .defaults)
            XCTFail("Expected \(category) failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, category)
            XCTAssertFalse(failure.technicalDetail?.contains("raw-") ?? false)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func fixtureText(named name: String) throws -> String {
        String(decoding: try analysisFixtureData(named: name), as: UTF8.self)
    }

    private func argument(after flag: String, in command: AnalysisProcessRunner.Command) -> String? {
        guard let index = command.arguments.firstIndex(of: flag), command.arguments.indices.contains(index + 1) else {
            return nil
        }
        return command.arguments[index + 1]
    }
}

actor AnalysisProcessRunner: ProcessRunning {
    struct Command: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
    }

    private var results: [ProcessResult]
    private var recordedCommands: [Command] = []

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        recordedCommands.append(Command(executable: executable, arguments: arguments))
        guard !results.isEmpty else {
            throw NSError(domain: "AnalysisProcessRunner", code: 1)
        }
        return results.removeFirst()
    }

    func commands() -> [Command] {
        recordedCommands
    }

    func commandCount() -> Int {
        recordedCommands.count
    }
}
