import AVFoundation
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class MP4OutputToolIntegrationTests: XCTestCase {
    @MainActor
    func testBundled4KEncodeProbeAndAppleDecode() async throws {
        guard ProcessInfo.processInfo.environment["YTDP_RUN_MP4_TOOL_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt-in synthetic 4K test requires system VideoToolbox access")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ffmpeg = root.appendingPathComponent("tools/ffmpeg")
        let ffprobe = root.appendingPathComponent("tools/ffprobe")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ytdp-mp4-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.mkv")
        let outputURL = directory.appendingPathComponent("compatible.mp4")
        let planner = MP4OutputPlanner()
        try run(ffmpeg, ["-hide_banner", "-nostdin", "-n", "-f", "lavfi", "-i",
            "testsrc2=size=3840x2160:rate=24:duration=2,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=limited",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
            "-c:v", "ffv1", "-level", "3", "-c:a", "pcm_s16le", sourceURL.path], log: directory.appendingPathComponent("generate.log"))
        let source = try probe(ffprobe, sourceURL, directory: directory)
        // This initial encode is the capability probe, not a grant based on encoder listing.
        let candidate = MP4OutputPlan(videoAction: .encode(.videoToolbox), audioAction: .aac, source: source, mode: .quickTimeCompatible)
        try run(ffmpeg, candidate.arguments(input: sourceURL, output: outputURL), log: directory.appendingPathComponent("encode.log"))
        let output = try probe(ffprobe, outputURL, directory: directory)
        var capabilities = MP4EncoderCapabilities()
        try capabilities.recordProbe(encoder: .videoToolbox, exitCode: 0, source: source, output: output)
        let accepted = try planner.plan(media: source, mode: .quickTimeCompatible, capabilities: capabilities)
        XCTAssertEqual(accepted.videoAction, .encode(.videoToolbox))
        try planner.validate(output: output, source: source, mode: .quickTimeCompatible)
        XCTAssertEqual(output.primaryVideo?.width, 3840)
        XCTAssertEqual(output.primaryVideo?.height, 2160)
        XCTAssertEqual(output.primaryVideo?.frameCount, "48")
        XCTAssertEqual(output.primaryVideo?.codecTag, "hvc1")
        XCTAssertEqual(output.primaryAudio?.codecName, "aac")

        let asset = AVURLAsset(url: outputURL)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let generator = AVAssetImageGenerator(asset: asset)
        let (frame, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertEqual(frame.width, 3840)
        XCTAssertEqual(frame.height, 2160)

        let rotatedURL = directory.appendingPathComponent("rotated.mp4")
        try run(ffmpeg, ["-nostdin", "-n", "-display_rotation:v:0", "90", "-i", outputURL.path, "-c", "copy", rotatedURL.path], log: directory.appendingPathComponent("rotate.log"))
        let rotated = try probe(ffprobe, rotatedURL, directory: directory)
        let rotatedCopy = directory.appendingPathComponent("rotated-copy.mp4")
        let copyPlan = try planner.plan(media: rotated, mode: .quickTimeCompatible, capabilities: .init())
        try run(ffmpeg, copyPlan.arguments(input: rotatedURL, output: rotatedCopy), log: directory.appendingPathComponent("rotate-copy.log"))
        try planner.validate(output: probe(ffprobe, rotatedCopy, directory: directory), source: rotated, mode: .quickTimeCompatible)
        XCTAssertEqual(rotated.primaryVideo?.displayWidth, 2160)

        let hdrURL = directory.appendingPathComponent("hdr.mp4")
        try run(ffmpeg, ["-nostdin", "-n", "-f", "lavfi", "-i",
            "testsrc2=size=3840x2160:rate=24:duration=1,format=p010le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=limited",
            "-c:v", "hevc_videotoolbox", "-allow_sw", "0", "-profile:v", "main10", "-q:v", "65", "-tag:v", "hvc1", hdrURL.path], log: directory.appendingPathComponent("hdr.log"))
        let hdr = try probe(ffprobe, hdrURL, directory: directory)
        XCTAssertTrue(hdr.primaryVideo?.isHDR == true)
        let hdrPlan = try planner.plan(media: hdr, mode: .quickTimeCompatible, capabilities: .init())
        XCTAssertEqual(hdrPlan.videoAction, .copy)
        let hdrCopy = directory.appendingPathComponent("hdr-copy.mp4")
        try run(ffmpeg, hdrPlan.arguments(input: hdrURL, output: hdrCopy), log: directory.appendingPathComponent("hdr-copy.log"))
        try planner.validate(output: probe(ffprobe, hdrCopy, directory: directory), source: hdr, mode: .quickTimeCompatible)

        let vfrURL = directory.appendingPathComponent("vfr.mkv")
        try run(ffmpeg, ["-nostdin", "-n", "-f", "lavfi", "-i",
            "testsrc2=size=3840x2160:rate=24:duration=2,select='not(eq(mod(n,5),0))',setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=limited",
            "-fps_mode", "passthrough", "-c:v", "ffv1", "-level", "3", vfrURL.path], log: directory.appendingPathComponent("vfr.log"))
        let vfr = try probe(ffprobe, vfrURL, directory: directory)
        let vfrOutput = directory.appendingPathComponent("vfr-compatible.mp4")
        let vfrPlan = try planner.plan(media: vfr, mode: .quickTimeCompatible, capabilities: capabilities)
        try run(ffmpeg, vfrPlan.arguments(input: vfrURL, output: vfrOutput), log: directory.appendingPathComponent("vfr-encode.log"))
        try planner.validate(output: probe(ffprobe, vfrOutput, directory: directory), source: vfr, mode: .quickTimeCompatible)
        let beforeTimes = try frameTimes(ffprobe, vfrURL, directory: directory)
        let afterTimes = try frameTimes(ffprobe, vfrOutput, directory: directory)
        XCTAssertEqual(beforeTimes.count, afterTimes.count)
        for (before, after) in zip(beforeTimes, afterTimes) {
            XCTAssertEqual(before - beforeTimes[0], after - afterTimes[0], accuracy: 0.002)
        }
        print("MP4 synthetic evidence: \(directory.path)")
    }

    private func frameTimes(_ executable: URL, _ media: URL, directory: URL) throws -> [Double] {
        let json = directory.appendingPathComponent(media.lastPathComponent + ".frames.json")
        try run(executable, ["-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", media.path], log: json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        let frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        let times = try frames.map { try XCTUnwrap(($0["best_effort_timestamp_time"] as? String).flatMap(Double.init)) }
        XCTAssertFalse(times.isEmpty)
        return times
    }

    private func probe(_ executable: URL, _ media: URL, directory: URL) throws -> ProbedMedia {
        let json = directory.appendingPathComponent(media.lastPathComponent + ".json")
        try run(executable, ["-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", media.path], log: json)
        return try JSONDecoder().decode(ProbedMedia.self, from: Data(contentsOf: json))
    }

    private func run(_ executable: URL, _ arguments: [String], log: URL) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("Tool failed; see \(log.path)")
            throw MP4OutputPlanningError.encoderProbeFailed
        }
    }
}
