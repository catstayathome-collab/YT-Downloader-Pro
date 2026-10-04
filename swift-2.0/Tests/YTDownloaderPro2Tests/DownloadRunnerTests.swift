import AVFoundation
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class DownloadRunnerTests: XCTestCase {
    func testProgressiveWebMIsRemuxedIntoOwnedMP4SourceBeforeVerification() async throws {
        let fixture = try RunnerFixture(mode: "success-progressive-webm")
        let events = try await collect(fixture.runner.events(for: fixture.job()))
        XCTAssertEqual(events.last, .completed)
        XCTAssertTrue(fixture.commandLog().contains("--remux-video mp4"))
        XCTAssertEqual(fixture.pipelineTrace(), ["probe:source.mp4", "encode:converted.mp4", "probe:converted.mp4"])
    }

    func testExplicitAudioSelectionCannotPublishSilentSource() async throws {
        let fixture = try RunnerFixture(mode: "success")
        var job = fixture.job()
        job.options.audioQuality = .format(id: "140", label: "AAC")
        do {
            _ = try await collect(fixture.runner.events(for: job))
            XCTFail("A requested audio track must not disappear silently")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .postProcessingFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertFalse(fixture.pipelineTrace().contains("encode:converted.mp4"))
    }

    func testQuitDuringCrashRecoveryPreservesPublishedCandidateIdentity() async throws {
        let fixture = try RunnerFixture(mode: "success-wait-source")
        let job = fixture.job()
        let workspace = try MP4Workspace(directory: fixture.directory, jobID: job.id)
        try workspace.prepareRequest(for: job)
        try Data("fixture".utf8).write(to: workspace.source)
        try Data("fixture".utf8).write(to: workspace.candidate)
        try workspace.retainVerifiedSource(for: job)
        try workspace.publish(to: fixture.finalURL)
        try job.id.uuidString.write(to: fixture.markerURL(basename: "Example video"), atomically: true, encoding: .utf8)
        let running = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.directory.appendingPathComponent("phase-started"))
        await fixture.runner.interruptForQuit(jobID: job.id)
        _ = try await running.value
        XCTAssertTrue(workspace.isPublished(to: fixture.finalURL))
        try "mode=success".write(to: fixture.directory.appendingPathComponent("fixture-mode"), atomically: true, encoding: .utf8)
        let events = try await collect(fixture.runner.events(for: job))
        XCTAssertEqual(events.last, .completed)
        XCTAssertTrue(fixture.traceLines().isEmpty)
    }

    func testActualHighResolutionCannotBypassFreeOrExpiredProAtPublication() async throws {
        for allowedChecks in [0, 2] {
            let policy = PipelinePolicyGate(allowedChecks: allowedChecks)
            let fixture = try RunnerFixture(mode: "success-high-resolution", policyProvider: { await policy.context() })
            do {
                _ = try await collect(fixture.runner.events(for: fixture.job()))
                XCTFail("Actual 2160p must not publish under Free")
            } catch is DownloadPolicyDeniedError {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
            XCTAssertEqual(fixture.pipelineTrace().contains("encode:converted.mp4"), allowedChecks == 2)
        }
    }

    func testOriginalModeDoesNotAcquireEncoderOrTranscodeVideo() async throws {
        let fixture = try RunnerFixture(mode: "success-convert-original")
        var job = fixture.job()
        job.options.mp4OutputMode = .originalEncoding
        let events = try await collect(fixture.runner.events(for: job))
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(fixture.pipelineTrace(), ["probe:source.mp4", "encode:converted.mp4", "probe:converted.mp4"])
        XCTAssertFalse(fixture.mediaCommandLog().contains("hevc_videotoolbox"))
        XCTAssertTrue(fixture.mediaCommandLog().contains("-c copy"))
    }

    @MainActor
    func testRealBundledRunnerConverts4KAndPreservesSubtitlesAndMetadata() async throws {
        guard ProcessInfo.processInfo.environment["YTDP_RUN_MP4_TOOL_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt-in runner integration requires VideoToolbox access")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent("tools")
        let fixture = try RunnerFixture(mode: "success", mediaToolsDirectory: tools)
        let subtitle = fixture.directory.appendingPathComponent("fixture.srt")
        try "1\n00:00:00,000 --> 00:00:00,500\nSubtitle fixture\n".write(to: subtitle, atomically: true, encoding: .utf8)
        let launcher = SystemProcessLauncher()
        let cover = fixture.directory.appendingPathComponent("cover.png")
        let coverResult = try await launcher.run(executable: tools.appendingPathComponent("ffmpeg"), arguments: [
            "-hide_banner", "-nostdin", "-n", "-f", "lavfi", "-i", "color=c=red:size=64x64", "-frames:v", "1", cover.path])
        XCTAssertEqual(coverResult.exitCode, 0, coverResult.stderr)
        let generated = try await launcher.run(executable: tools.appendingPathComponent("ffmpeg"), arguments: [
            "-hide_banner", "-nostdin", "-n", "-f", "lavfi", "-i",
            "testsrc2=size=3840x2160:rate=24:duration=0.5,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=limited",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
            "-i", subtitle.path, "-i", cover.path, "-map", "0:v", "-map", "1:a", "-map", "2:s", "-map", "3:v",
            "-c:v", "mpeg4", "-q:v", "3", "-c:v:1", "png", "-disposition:v:1", "attached_pic", "-c:a", "aac", "-c:s", "mov_text",
            "-metadata", "title=Runner fixture", "-metadata:s:s:0", "language=jpn",
            fixture.directory.appendingPathComponent("real-source.mp4").path])
        XCTAssertEqual(generated.exitCode, 0, generated.stderr)
        let events = try await collect(fixture.runner.events(for: fixture.job()))
        XCTAssertEqual(events.last, .completed)
        let result = try await launcher.run(executable: tools.appendingPathComponent("ffprobe"), arguments: [
            "-v", "error", "-show_streams", "-show_format", "-of", "json", fixture.finalURL.path])
        let media = try JSONDecoder().decode(ProbedMedia.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(media.primaryVideo?.height, 2160)
        XCTAssertEqual(media.primaryVideo?.codecName, "hevc")
        XCTAssertEqual(media.primaryVideo?.codecTag, "hvc1")
        XCTAssertEqual(media.primaryAudio?.codecName, "aac")
        XCTAssertEqual(media.subtitles.first?.tags?["language"], "jpn")
        XCTAssertEqual(media.artwork.count, 1)
        XCTAssertEqual(media.artwork.first?.width, 64)
        XCTAssertTrue(result.stdout.contains("Runner fixture"))
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("Example video.ja.srt")), try Data(contentsOf: subtitle))
        let asset = AVURLAsset(url: fixture.finalURL)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let generator = AVAssetImageGenerator(asset: asset)
        let (frame, _) = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
        XCTAssertEqual(frame.height, 2160)
        print("Runner media evidence: \(fixture.directory.path)")
    }

    func testCompatiblePipelineProbesRemuxesAndValidatesBeforeCompletion() async throws {
        let fixture = try RunnerFixture(mode: "success")
        let events = try await collect(fixture.runner.events(for: fixture.job()))
        XCTAssertEqual(fixture.pipelineTrace(), ["probe:source.mp4", "encode:converted.mp4", "probe:converted.mp4"])
        XCTAssertEqual(events.last, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingDirectory.path))
    }

    func testIncompatibleSourceRequiresSuccessfulEncoderProbeAndFinalValidation() async throws {
        let fixture = try RunnerFixture(mode: "success-convert")
        let events = try await collect(fixture.runner.events(for: fixture.job()))
        XCTAssertEqual(fixture.pipelineTrace(), ["probe:source.mp4", "encode:probe-hevc_videotoolbox.mp4",
            "probe:probe-hevc_videotoolbox.mp4", "encode:converted.mp4", "probe:converted.mp4"])
        XCTAssertEqual(events.last, .completed)
    }

    func testFailedFinalProbeAndDiskFullNeverPublish() async throws {
        for mode in ["success-bad-final", "success-encode-disk-full", "success-convert-no-encoder", "success-convert-unknown-color"] {
            let fixture = try RunnerFixture(mode: mode)
            do {
                _ = try await collect(fixture.runner.events(for: fixture.job()))
                XCTFail("Expected failure: \(mode)")
            } catch let failure as DownloadFailure {
                let expected: DownloadFailure.Category = mode.contains("disk-full") ? .diskFull :
                    mode.contains("no-encoder") ? .compatibleEncoderUnavailable :
                    mode.contains("unknown-color") ? .unsupportedMediaConversion : .postProcessingFailed
                XCTAssertEqual(failure.category, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
            XCTAssertEqual(fixture.scope.stopCount, 1)
        }
    }

    func testCancelWaitsForEveryMediaPhaseAndNeverPublishes() async throws {
        for mode in ["success-wait-source", "success-wait-capability", "success-wait-encode", "success-wait-final"] {
            let fixture = try RunnerFixture(mode: mode)
            let job = fixture.job()
            let task = Task { try await collect(fixture.runner.events(for: job)) }
            try await fixture.waitForFile(fixture.directory.appendingPathComponent("phase-started"))
            let accepted = await fixture.runner.pause(jobID: job.id)
            XCTAssertFalse(accepted)
            await fixture.runner.cancel(jobID: job.id)
            let events = try await task.value
            XCTAssertEqual(fixture.pipelineTrace().last, "stopped")
            XCTAssertFalse(events.contains(.completed))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingDirectory.path))
            XCTAssertEqual(fixture.scope.stopCount, 1)
        }
    }

    func testQuitDuringConversionRetainsVerifiedSourceAndRestartsWithoutRedownload() async throws {
        let fixture = try RunnerFixture(mode: "success-wait-encode")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.directory.appendingPathComponent("phase-started"))
        await fixture.runner.interruptForQuit(jobID: job.id)
        let events = try await task.value
        XCTAssertFalse(events.contains(.completed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingDirectory.appendingPathComponent("converted.mp4").path))
        try "mode=success".write(to: fixture.directory.appendingPathComponent("fixture-mode"), atomically: true, encoding: .utf8)
        let resumed = try await collect(fixture.runner.events(for: job))
        XCTAssertEqual(resumed.last, .completed)
        XCTAssertEqual(fixture.traceLines(), ["download"])
    }

    func testInvalidActualProbeCannotCompleteEvenAfterDownloaderSuccess() async throws {
        let fixture = try RunnerFixture(mode: "success-invalid-probe")
        var completed = false
        do {
            for try await event in fixture.runner.events(for: fixture.job()) {
                if event == .completed { completed = true }
            }
            XCTFail("An invalid media probe must fail the job")
        } catch {}
        XCTAssertFalse(completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
    }

    func testSuccessfulRunEmitsReservedBasenameAndVerifiedCompletionInOrder() async throws {
        // Completing from exit code without a reserved, existing final file would make this pass incorrectly.
        let fixture = try RunnerFixture(mode: "success")
        let events = try await collect(fixture.runner.events(for: fixture.job()))

        XCTAssertEqual(events.compactMap(phase), [.analyzing, .downloading, .merging, .postprocessing])
        XCTAssertEqual(events.compactMap(reservedBasename).count, 1)
        XCTAssertEqual(events.last, .completed)
        XCTAssertTrue(events.contains(.output(fixture.finalURL)))
        let finalProgress = events.compactMap { event -> JobProgress? in
            guard case let .progress(progress) = event else { return nil }
            return progress
        }.last
        XCTAssertEqual(
            finalProgress,
            JobProgress(
                fraction: 1,
                downloadedBytes: 7,
                totalBytes: 7,
                bytesPerSecond: nil,
                etaSeconds: 0
            )
        )
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testDownloadArgumentsUseResolvedReservationDirectoryInsteadOfDisplayPath() async throws {
        // Clearing outputURL after reservation would send yt-dlp to this stale display path.
        let fixture = try RunnerFixture(mode: "success", displayDirectory: "/tmp/stale-display-directory")
        _ = try await collect(fixture.runner.events(for: fixture.job()))

        XCTAssertTrue(fixture.commandLog().contains("\(fixture.stagingDirectory.path)/source.%(ext)s"))
        XCTAssertFalse(fixture.commandLog().contains("/tmp/stale-display-directory"))
    }

    func testCredentialBearingJobURLFailsBeforeLaunchingHelper() async throws {
        // Validating only UI input or persistence would let direct runner jobs pass credentials to yt-dlp.
        let fixture = try RunnerFixture(mode: "success")
        var job = fixture.job()
        job.sourceURL = "https://runner-user:runner-password@fake.test/success?state=\(fixture.directory.path)"

        do {
            _ = try await collect(fixture.runner.events(for: job))
            XCTFail("Expected unsafe source URL failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .invalidURL)
            XCTAssertFalse(failure.technicalDetail?.contains("runner-password") == true)
        }
        XCTAssertEqual(fixture.scope.startCount, 0)
        XCTAssertTrue(fixture.commandLog().isEmpty)
    }

    func testFreePlanDeniesRestrictedVideoSelectionsBeforeAnySideEffect() async throws {
        let cases: [(MediaFormat?, FeatureID, FeatureDenialReason)] = [
            (
                mediaFormat(id: "1080", height: 1_080),
                .videoHD,
                .videoHeightRequiresPro
            ),
            (
                mediaFormat(id: "source", height: 720, note: "Source"),
                .videoUHD,
                .sourceQualityRequiresPro
            ),
            (
                mediaFormat(id: "unknown", height: nil),
                .videoHD,
                .unknownVideoHeight
            )
        ]

        for (format, feature, reason) in cases {
            let fixture = try RunnerFixture(
                mode: "success",
                featurePolicyContext: AppPlan.free.featurePolicyContext
            )

            do {
                _ = try await collect(fixture.runner.events(for: fixture.job(videoFormat: format)))
                XCTFail("Expected Free policy denial for \(reason)")
            } catch let denial as DownloadPolicyDeniedError {
                XCTAssertEqual(denial.denial.requiredFeature, feature)
                XCTAssertEqual(denial.denial.reason, reason)
            }

            XCTAssertEqual(fixture.scope.startCount, 0)
            XCTAssertEqual(fixture.scope.stopCount, 0)
            XCTAssertTrue(fixture.commandLog().isEmpty)
            XCTAssertTrue(fixture.reservationMarkers().isEmpty)
        }
    }

    func testFreeBestIsCappedInActualDownloadIncludingRetry() async throws {
        for mode in ["success", "retry-403"] {
            let fixture = try RunnerFixture(mode: mode, featurePolicyContext: AppPlan.free.featurePolicyContext)
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTAssertTrue(fixture.commandLog().contains("bestvideo[height<=720]+bestaudio/best[height<=720]"))
            if mode == "retry-403" {
                XCTAssertFalse(fixture.commandLog().split(separator: "\n").last?.contains("--extractor-args") ?? true)
            }
        }
    }

    func testFreeExplicitSelectionHasExecutionHeightGuard() async throws {
        let fixture = try RunnerFixture(mode: "success", featurePolicyContext: AppPlan.free.featurePolicyContext)
        _ = try await collect(fixture.runner.events(for: fixture.job(videoFormat: mediaFormat(id: "137", height: 720))))
        XCTAssertTrue(fixture.commandLog().contains("137[height<=720]+bestaudio"))
    }

    func testRetryRefreshesMetadataBeforeFreePolicyCheck() async throws {
        let fixture = try RunnerFixture(mode: "retry-403", featurePolicyContext: AppPlan.free.featurePolicyContext)
        do {
            _ = try await collect(fixture.runner.events(for: fixture.job(videoFormat: mediaFormat(id: "137", height: 720))))
            XCTFail("Refreshed format has no verified height")
        } catch let error as DownloadPolicyDeniedError {
            XCTAssertEqual(error.denial.reason, .unknownVideoHeight)
        }
        XCTAssertEqual(fixture.traceLines().filter { $0 == "download" }.count, 1)
    }

    func testFreePlanAllowsMP3BeforeRunnerSideEffectsProceed() async throws {
        let fixture = try RunnerFixture(
            mode: "success",
            featurePolicyContext: AppPlan.free.featurePolicyContext
        )
        var job = fixture.job()
        job.options.selectOutputKind(.mp3)

        do {
            _ = try await collect(fixture.runner.events(for: job))
        } catch is DownloadFailure {
            // The fixture always writes an MP4; reaching that verification proves policy admission.
        }

        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertFalse(fixture.commandLog().isEmpty)
    }

    func testExitZeroWithoutOwnedFinalOutputFailsInsteadOfCompleting() async throws {
        // Removing final-output verification would emit completed for this zero-exit process.
        let fixture = try RunnerFixture(mode: "no-final")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTFail("Expected missing-final-output failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .downloadFailed)
        }
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testDownloadFailuresUseStableActionableCategories() async throws {
        let cases: [(String, DownloadFailure.Category)] = [
            ("permission-error", .outputPermissionDenied),
            ("disk-full", .diskFull),
            ("postprocess-error", .postProcessingFailed)
        ]

        for (mode, expected) in cases {
            let fixture = try RunnerFixture(mode: mode)
            do {
                _ = try await collect(fixture.runner.events(for: fixture.job()))
                XCTFail("Expected \(expected)")
            } catch let failure as DownloadFailure {
                XCTAssertEqual(failure.category, expected, mode)
            }
        }
    }

    func testPausePreservesPartAndMarkerAndResumeReusesBasenameWithContinue() async throws {
        // Releasing a paused reservation or omitting --continue would lose resumable ownership.
        let fixture = try RunnerFixture(mode: "pause")
        let initialJob = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: initialJob)) }
        try await fixture.waitForFile(fixture.partURL)

        let pauseAccepted = await fixture.runner.pause(jobID: initialJob.id)
        let pausedEvents = try await task.value

        XCTAssertTrue(pauseAccepted)
        let basename = try XCTUnwrap(pausedEvents.compactMap(reservedBasename).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))

        let resumeJob = fixture.job(id: initialJob.id, reservedBasename: basename)
        let resumed = Task { try await collect(fixture.runner.events(for: resumeJob)) }
        try await fixture.waitForTraceLines(2)
        await fixture.runner.cancel(jobID: initialJob.id)
        _ = try await resumed.value

        XCTAssertTrue(fixture.commandLog().contains("--continue"))
    }

    func testCancelPausedJobReacquiresOwnedReservationAndRemovesPartialAndMarker() async throws {
        let fixture = try RunnerFixture(mode: "pause")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        XCTAssertTrue(pauseAccepted)
        let events = try await task.value
        let basename = try XCTUnwrap(events.compactMap(reservedBasename).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))

        await fixture.runner.cleanupCancelledJob(fixture.job(id: job.id, reservedBasename: basename))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
    }

    func testDiscardCleanupKeepsReservationMarkerWhenOwnedPartialCannotBeDeleted() async throws {
        let fixture = try RunnerFixture(mode: "success")
        let job = fixture.job(reservedBasename: "Example video")
        _ = try MP4Workspace(directory: fixture.directory, jobID: job.id)
        try job.id.uuidString.write(
            to: fixture.markerURL(basename: "Example video"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: fixture.partURL, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: fixture.partURL.appendingPathComponent("fragment"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.partURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.partURL.path)
        }

        let cleaned = await fixture.runner.cleanupCancelledJob(job)

        XCTAssertFalse(cleaned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: "Example video").path))
    }

    func testPauseDuringMergeIsRejectedAndLeavesProcessRunning() async throws {
        // Interrupting a merger through an ordinary pause would destroy a non-resumable output.
        let fixture = try RunnerFixture(mode: "merge")
        let job = fixture.job(videoFormatID: "137")
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.merging))

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pauseAccepted)
        XCTAssertEqual(fixture.traceLines().filter { $0 == "download" }.count, 1)
        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value
    }

    func testPauseDuringPostprocessingIsRejectedAndLeavesProcessRunning() async throws {
        let fixture = try RunnerFixture(mode: "postprocess")
        let job = fixture.job()
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.postprocessing))

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(pauseAccepted)
        XCTAssertEqual(fixture.traceLines().filter { $0 == "download" }.count, 1)
        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value
    }

    func testCancelRemovesOnlyOwnedIncompleteArtifactsAndMarker() async throws {
        // Prefix or glob cleanup would remove the foreign file or completed media in this fixture.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.foreignPartURL)
        let basename = "Example video"

        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatPartFragmentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatYTDLURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.foreignPartURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.foreignFragmentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.invalidFragmentURL.path))
    }

    func testCancelDuringMergeRemovesOwnedIncompleteDestinationAndMarker() async throws {
        let fixture = try RunnerFixture(mode: "merge")
        let job = fixture.job(videoFormatID: "137")
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.merging))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))

        await fixture.runner.cancel(jobID: job.id)
        _ = try await task.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.markerURL(basename: "Example video").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.formatPartURL.path))
    }

    func testCancelWaitsForTerminationAndSkipsCleanupWhenReservationOwnershipIsReplaced() async throws {
        // Deleting before an ownership check would remove these artifacts after the marker is replaced.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)
        let foreignID = UUID()
        try foreignID.uuidString.write(to: fixture.markerURL(basename: "Example video"), atomically: true, encoding: .utf8)

        await fixture.runner.cancel(jobID: job.id)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.formatURL.path))
        XCTAssertEqual(try String(contentsOf: fixture.markerURL(basename: "Example video"), encoding: .utf8), foreignID.uuidString)
    }

    func testRepeatedCancelCallsShareTerminalCleanup() async throws {
        // A second caller must wait for the same cleanup instead of racing scope release or deadlocking the actor.
        let fixture = try RunnerFixture(mode: "cancel")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        async let first: Void = fixture.runner.cancel(jobID: job.id)
        async let second: Void = fixture.runner.cancel(jobID: job.id)
        _ = await (first, second)

        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partURL.path))
    }

    func testQuitDuringMergeDeletesOnlyIncompleteDestinationAndPreservesSourcePartial() async throws {
        // Treating quit like cancel would erase resumable source streams.
        let fixture = try RunnerFixture(mode: "merge")
        let job = fixture.job(videoFormatID: "137")
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.sourceURL)
        let basename = "Example video"

        await fixture.runner.interruptForQuit(jobID: job.id)
        _ = try await task.value

        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.formatPartURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: basename).path))
    }

    func testQuitWaitsForMergeTerminationBeforeReturning() async throws {
        // Returning after only INT leaves the scoped folder and incomplete merge output live.
        let fixture = try RunnerFixture(mode: "merge-ignore-int")
        let job = fixture.job(videoFormatID: "137")
        let events = EventRecorder()
        let task = Task { () throws -> [DownloadEvent] in
            var collected: [DownloadEvent] = []
            for try await event in fixture.runner.events(for: job) {
                collected.append(event)
                await events.record(event)
            }
            return collected
        }
        await events.wait(for: .phase(.merging))

        await fixture.runner.interruptForQuit(jobID: job.id)

        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value
    }

    func testRetryable403ReanalyzesBeforeOneBoundedRetry() async throws {
        // Retrying every failure or skipping reanalysis would change the trace and phase sequence.
        let fixture = try RunnerFixture(mode: "retry-403")
        let events = try await collect(fixture.runner.events(for: fixture.job()))

        XCTAssertEqual(events.compactMap(phase), [.analyzing, .downloading, .analyzing, .downloading, .postprocessing])
        XCTAssertEqual(fixture.traceLines(), ["download", "download"])
        XCTAssertEqual(fixture.analysisTraceLines(), ["analysis"])
    }

    func testArbitraryFailureDoesNotRetry() async throws {
        // Broad retry matching would run the fake downloader a second time.
        let fixture = try RunnerFixture(mode: "arbitrary-error")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTFail("Expected a download failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .downloadFailed)
        }
        XCTAssertEqual(fixture.traceLines(), ["download"])
    }

    func testMissingSavedFormatAfterReanalysisRequiresReselection() async throws {
        // Silently accepting a reanalysis without the saved format would download changed quality.
        let fixture = try RunnerFixture(mode: "missing-format")

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job(videoFormatID: "137")))
            XCTFail("Expected format reselection failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .formatReselectionRequired)
        }
        XCTAssertEqual(fixture.traceLines(), ["download"])
        XCTAssertEqual(fixture.analysisTraceLines(), ["analysis"])
    }

    func testDuplicateRunAndConsumerCancellationDoNotLeakProcessOrScope() async throws {
        // Forgetting stream-termination cleanup leaves the helper and its security scope alive.
        let fixture = try RunnerFixture(mode: "consumer-cancel")
        let job = fixture.job()
        let first = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        do {
            _ = try await collect(fixture.runner.events(for: job))
            XCTFail("Expected duplicate active job failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .downloadFailed)
        }

        first.cancel()
        _ = await first.result
        try await fixture.waitForScopeStop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testCancelStopsTrackedReanalysisBeforeReturning() async throws {
        // Calling MetadataProbe through opaque run leaves this reanalysis process outside cancellation control.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        try await completeWithin(nanoseconds: 1_500_000_000) {
            await fixture.runner.cancel(jobID: job.id)
        }
        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value

        XCTAssertEqual(fixture.traceLines(), ["download"])
    }

    func testConsumerCancellationStopsTrackedReanalysis() async throws {
        // A cancelled stream consumer must interrupt the analysis helper, not only detach from its events.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        task.cancel()
        _ = await task.result
        try await fixture.waitForScopeStop(timeoutNanoseconds: 1_500_000_000)

        XCTAssertEqual(fixture.scope.stopCount, 1)
    }

    func testPauseStopsTrackedReanalysis() async throws {
        // Treating reanalysis as an opaque probe would leave its helper alive after a pause.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        _ = try await task.value

        XCTAssertTrue(pauseAccepted)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: "Example video").path))
    }

    func testQuitWaitsForTrackedReanalysisTermination() async throws {
        // Quit must not return while a retry-analysis helper still owns the security scope.
        let fixture = try RunnerFixture(mode: "retry-analysis-wait")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.analysisStartedURL)

        await fixture.runner.interruptForQuit(jobID: job.id)

        XCTAssertEqual(fixture.scope.stopCount, 1)
        _ = try await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL(basename: "Example video").path))
    }

    func testPauseEscalatesToTerminationWhenHelperIgnoresInterrupt() async throws {
        // Sending only INT leaves this helper running forever.
        let fixture = try RunnerFixture(mode: "ignore-int")
        let job = fixture.job()
        let task = Task { try await collect(fixture.runner.events(for: job)) }
        try await fixture.waitForFile(fixture.partURL)

        let pauseAccepted = await fixture.runner.pause(jobID: job.id)
        _ = try await task.value

        XCTAssertTrue(pauseAccepted)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.partURL.path))
    }

    func testLaunchFailureReleasesScopeAndReservation() async throws {
        // A pre-launch failure must not retain a marker or security-scoped folder access.
        let fixture = try RunnerFixture(mode: "success", launchable: false)
        let job = fixture.job()

        do {
            _ = try await collect(fixture.runner.events(for: job))
            XCTFail("Expected launch failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .bundledDownloaderUnavailable)
        }
        XCTAssertEqual(fixture.scope.startCount, 1)
        XCTAssertEqual(fixture.scope.stopCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasSuffix(".ytdp-reservation") })
    }

    func testLaunchFailureForcesToolchainRecheckAndUsesConverterFailureWhenValidationFindsIt() async throws {
        let gate = RunnerToolchainGate(results: [
            .success(.fixture),
            .failure(DownloadFailure(category: .bundledConverterUnavailable))
        ])
        let fixture = try RunnerFixture(mode: "success", launchable: false, toolchainValidator: gate)

        do {
            _ = try await collect(fixture.runner.events(for: fixture.job()))
            XCTFail("Expected launch failure")
        } catch let failure as DownloadFailure {
            XCTAssertEqual(failure.category, .bundledConverterUnavailable)
        }
        let gateArguments = await gate.forcedArguments()
        XCTAssertEqual(gateArguments, [false, true])
    }

    private func phase(_ event: DownloadEvent) -> DownloadPhase? {
        guard case let .phase(value) = event else { return nil }
        return value
    }

    private func reservedBasename(_ event: DownloadEvent) -> String? {
        guard case let .reservedBasename(value) = event else { return nil }
        return value
    }

    private func mediaFormat(
        id: String,
        height: Int?,
        note: String? = nil
    ) -> MediaFormat {
        MediaFormat(
            id: id,
            label: id,
            codec: nil,
            videoCodec: "avc1",
            audioCodec: nil,
            container: "mp4",
            width: nil,
            height: height,
            resolution: nil,
            framesPerSecond: nil,
            bitrate: nil,
            language: nil,
            estimatedFileSize: nil,
            note: note
        )
    }
}

private final class RunnerFixture: @unchecked Sendable {
    let directory: URL
    let executable: URL
    let scope = SecurityScopeRecorder()
    let runner: DownloadRunner
    private var lastJobID = UUID()

    init(
        mode: String,
        launchable: Bool = true,
        displayDirectory: String? = nil,
        toolchainValidator: (any ToolchainHealthValidating)? = nil,
        featurePolicyContext: FeaturePolicyContext = .publicCompatibility,
        mediaToolsDirectory: URL? = nil,
        policyProvider: (@Sendable () async -> FeaturePolicyContext)? = nil
    ) throws {
        directory = try temporaryDirectory()
        let fixtureExecutable = try Self.copyFixtureScript(to: directory)
        if !launchable {
            executable = directory.appendingPathComponent("missing-yt-dlp")
        } else {
            executable = fixtureExecutable
        }
        let bookmarks = OutputDirectoryBookmarkService(
            makeBookmark: { _ in Data("fixture-bookmark".utf8) },
            resolveBookmark: { [directory] _ in .init(url: directory, isStale: false) },
            startAccessingSecurityScopedResource: { [scope] _ in
                scope.startCount += 1
                return true
            },
            stopAccessingSecurityScopedResource: { [scope] _ in scope.stopCount += 1 }
        )
        let toolchain = Toolchain(ytDLP: executable, ffmpeg: mediaToolsDirectory?.appendingPathComponent("ffmpeg") ?? executable,
            ffprobe: mediaToolsDirectory?.appendingPathComponent("ffprobe") ?? executable, qjs: executable)
        runner = DownloadRunner(
            toolchain: toolchain,
            allocator: OutputNameAllocator(),
            metadataProbe: MetadataProbe(toolchain: toolchain, processRunner: SystemProcessLauncher()),
            bookmarks: bookmarks,
            toolchainValidator: toolchainValidator,
            featurePolicyContextProvider: policyProvider ?? { featurePolicyContext },
            interruptGraceNanoseconds: 100_000_000
        )
        try "mode=\(mode)".write(to: directory.appendingPathComponent("fixture-mode"), atomically: true, encoding: .utf8)
        if let displayDirectory {
            try displayDirectory.write(to: directory.appendingPathComponent("fixture-display-directory"), atomically: true, encoding: .utf8)
        }
    }

    var finalURL: URL { directory.appendingPathComponent("Example video.mp4") }
    var stagingDirectory: URL { directory.appendingPathComponent(".ytdp-\(lastJobID.uuidString)") }
    var sourceURL: URL { stagingDirectory.appendingPathComponent("source.mp4") }
    var partURL: URL { stagingDirectory.appendingPathComponent("source.mp4.part") }
    var formatURL: URL { stagingDirectory.appendingPathComponent("source.f137.mp4") }
    var formatPartURL: URL { stagingDirectory.appendingPathComponent("source.f137.mp4.part") }
    var formatPartFragmentURL: URL { stagingDirectory.appendingPathComponent("source.f137.mp4.part-Frag1") }
    var formatYTDLURL: URL { stagingDirectory.appendingPathComponent("source.f137.mp4.ytdl") }
    var invalidFragmentURL: URL { directory.appendingPathComponent("Example video.f137.mp4.part-FragNotANumber") }
    var foreignPartURL: URL { directory.appendingPathComponent("Foreign.mp4.part") }
    var foreignFragmentURL: URL { directory.appendingPathComponent("Example video2.f137.mp4.part-Frag1") }
    var analysisStartedURL: URL { directory.appendingPathComponent("analysis-started") }

    func job(
        id: UUID = UUID(),
        reservedBasename: String? = nil,
        videoFormatID: String? = nil,
        videoFormat: MediaFormat? = nil
    ) -> DownloadJob {
        lastJobID = id
        var options = DownloadOptions.fixture()
        options.outputDirectoryBookmark = Data("fixture-bookmark".utf8)
        options.outputDirectoryDisplayPath = (try? String(contentsOf: directory.appendingPathComponent("fixture-display-directory"), encoding: .utf8)) ?? directory.path
        if let videoFormatID {
            options.videoQuality = .format(id: videoFormatID, label: "fixture")
        }
        if let videoFormat {
            options.selectVideoFormat(videoFormat)
        }
        let mode = (try? String(contentsOf: directory.appendingPathComponent("fixture-mode"), encoding: .utf8))?.replacingOccurrences(of: "mode=", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "success"
        return DownloadJob(
            id: id,
            sourceURL: "https://fake.test/\(mode)?state=\(directory.path)",
            title: "Example video",
            reservedOutputBasename: reservedBasename,
            options: options
        )
    }

    func markerURL(basename: String) -> URL {
        directory.appendingPathComponent(".\(basename).ytdp-reservation")
    }

    func traceLines() -> [String] {
        (try? String(contentsOf: directory.appendingPathComponent("Example video.fake-trace"), encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    func pipelineTrace() -> [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("pipeline.trace"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func mediaCommandLog() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("media-command"), encoding: .utf8)) ?? ""
    }

    func trace() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("Example video.fake-trace"), encoding: .utf8)) ?? ""
    }

    func commandLog() -> String {
        (try? String(contentsOf: directory.appendingPathComponent("Example video.fake-command"), encoding: .utf8)) ?? ""
    }

    func reservationMarkers() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasSuffix(".ytdp-reservation") } ?? []
    }

    func analysisTraceLines() -> [String] {
        (try? String(contentsOf: directory.appendingPathComponent("analysis.fake-trace"), encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    func waitForFile(_ url: URL) async throws {
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) }
    }

    func waitForTraceLines(_ count: Int) async throws {
        try await waitUntil { self.traceLines().count >= count }
    }

    func waitForScopeStop(timeoutNanoseconds: UInt64 = 3_000_000_000) async throws {
        try await waitUntil(timeoutNanoseconds: timeoutNanoseconds) { self.scope.stopCount == 1 }
    }

    private static func copyFixtureScript(to directory: URL) throws -> URL {
        guard let source = Bundle.module.url(forResource: "fake-yt-dlp", withExtension: "sh") else {
            throw NSError(domain: "RunnerFixture", code: 1)
        }
        let destination = directory.appendingPathComponent("fake-yt-dlp.sh")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw NSError(domain: "RunnerFixture", code: 2)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private actor PipelinePolicyGate {
    private var remaining: Int
    init(allowedChecks: Int) { remaining = allowedChecks }
    func context() -> FeaturePolicyContext {
        defer { remaining -= 1 }
        return remaining > 0 ? .publicCompatibility : AppPlan.free.featurePolicyContext
    }
}

private actor RunnerToolchainGate: ToolchainHealthValidating {
    private var results: [Result<ToolchainHealth, DownloadFailure>]
    private var arguments: [Bool] = []

    init(results: [Result<ToolchainHealth, DownloadFailure>]) {
        self.results = results
    }

    func validate(force: Bool) async throws -> ToolchainHealth {
        arguments.append(force)
        guard !results.isEmpty else { return .fixture }
        return try results.removeFirst().get()
    }

    func forcedArguments() -> [Bool] { arguments }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int {
        get { lock.withLock { starts } }
        set { lock.withLock { starts = newValue } }
    }

    var stopCount: Int {
        get { lock.withLock { stops } }
        set { lock.withLock { stops = newValue } }
    }
}

private actor EventRecorder {
    private var events: [DownloadEvent] = []
    private var waiters: [(DownloadEvent, CheckedContinuation<Void, Never>)] = []

    func record(_ event: DownloadEvent) {
        events.append(event)
        let matching = waiters.enumerated().filter { $0.element.0 == event }.map(\.offset)
        for index in matching.reversed() {
            waiters.remove(at: index).1.resume()
        }
    }

    func wait(for event: DownloadEvent) async {
        guard !events.contains(event) else { return }
        await withCheckedContinuation { continuation in
            waiters.append((event, continuation))
        }
    }
}

private func completeWithin<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let state = RunnerTimeoutState(continuation: continuation)
        Task.detached {
            do {
                state.resume(with: .success(try await operation()))
            } catch {
                state.resume(with: .failure(error))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(nanoseconds) / 1_000_000_000) {
            state.resume(with: .failure(RunnerTimeoutError.timedOut))
        }
    }
}

private final class RunnerTimeoutState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private enum RunnerTimeoutError: Error {
    case timedOut
}
