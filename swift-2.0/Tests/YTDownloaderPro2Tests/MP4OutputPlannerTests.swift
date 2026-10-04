import Foundation
import XCTest
@testable import YTDownloaderPro2

final class MP4OutputPlannerTests: XCTestCase {
    private let planner = MP4OutputPlanner()

    func testCompatibleStreamsCopyWithoutEncoder() throws {
        for codec in ["h264", "hevc"] {
            let source = try media(codec: codec)
            let plan = try planner.plan(media: source, mode: .quickTimeCompatible, capabilities: .init())
            XCTAssertEqual(plan.videoAction, .copy)
            XCTAssertEqual(plan.audioAction, .copy)
            XCTAssertFalse(plan.arguments(input: URL(fileURLWithPath: "/tmp/in"), output: URL(fileURLWithPath: "/tmp/out")).contains("-r"))
            try planner.validate(output: source, source: source, mode: .quickTimeCompatible)
        }
    }

    func testSDRVideoAndAudioArePlannedIndependently() throws {
        let capabilities = try verifiedCapabilities([.libx265, .videoToolbox])
        for codec in ["vp9", "av1"] {
            let plan = try planner.plan(media: media(codec: codec, audio: "opus"), mode: .quickTimeCompatible, capabilities: capabilities)
            XCTAssertEqual(plan.videoAction, .encode(.videoToolbox))
            XCTAssertEqual(plan.audioAction, .aac)
            let arguments = plan.arguments(input: URL(fileURLWithPath: "/tmp/in"), output: URL(fileURLWithPath: "/tmp/out"))
            XCTAssertTrue(arguments.contains("hvc1"))
            XCTAssertTrue(arguments.contains("passthrough"))
            XCTAssertFalse(arguments.contains("-vf"))
            XCTAssertFalse(arguments.contains("-r"))
        }
        let audioOnly = try planner.plan(media: media(audio: "opus"), mode: .quickTimeCompatible, capabilities: .init())
        XCTAssertEqual(audioOnly.videoAction, .copy)
        XCTAssertEqual(audioOnly.audioAction, .aac)
        let software = try planner.plan(media: media(codec: "vp9"), mode: .quickTimeCompatible, capabilities: verifiedCapabilities([.libx265]))
        XCTAssertEqual(software.videoAction, .encode(.libx265))
        XCTAssertThrowsError(try planner.plan(media: media(codec: "vp9"), mode: .quickTimeCompatible, capabilities: .init()))
    }

    func testCapabilityRequiresSuccessfulProbeAndExpectedEncoderOutput() throws {
        var capabilities = MP4EncoderCapabilities()
        let source = try media(codec: "vp9")
        XCTAssertThrowsError(try capabilities.recordProbe(encoder: .videoToolbox, exitCode: 1, source: source, output: media(codec: "hevc")))
        XCTAssertThrowsError(try capabilities.recordProbe(encoder: .videoToolbox, exitCode: 0, source: source, output: media(codec: "h264")))
        XCTAssertTrue(capabilities.verifiedEncoders.isEmpty)
        try capabilities.recordProbe(encoder: .libx265, exitCode: 0, source: source, output: media(codec: "hevc"))
        XCTAssertEqual(capabilities.verifiedEncoders, [.libx265])
    }

    func testOriginalModeNeverEncodesAndRejectsUnknownMuxCodecs() throws {
        for codec in ["h264", "hevc", "vp9", "av1"] {
            let source = try media(codec: codec, audio: "opus")
            let plan = try planner.plan(media: source, mode: .originalEncoding, capabilities: .init())
            XCTAssertEqual(plan.videoAction, .copy)
            XCTAssertEqual(plan.audioAction, .copy)
            try planner.validate(output: source, source: source, mode: .originalEncoding)
        }
        XCTAssertThrowsError(try planner.plan(media: media(codec: "theora"), mode: .originalEncoding, capabilities: .init()))
        XCTAssertThrowsError(try planner.validate(output: media(codec: "hevc"), source: media(codec: "vp9"), mode: .originalEncoding))
    }

    func testHDRCopiesOnlySupportedHEVCAndRejectsConversionOrUnknownColor() throws {
        for transfer in ["smpte2084", "arib-std-b67"] {
            let hdr = try media(codec: "hevc", pixel: "yuv420p10le", transfer: transfer, primaries: "bt2020", space: "bt2020nc")
            XCTAssertEqual(try planner.plan(media: hdr, mode: .quickTimeCompatible, capabilities: .init()).videoAction, .copy)
            XCTAssertThrowsError(try planner.plan(media: media(codec: "vp9", pixel: "yuv420p10le", transfer: transfer, primaries: "bt2020", space: "bt2020nc"), mode: .quickTimeCompatible, capabilities: verifiedCapabilities([.libx265])))
        }
        XCTAssertThrowsError(try planner.plan(media: media(codec: "av1", transfer: "unknown"), mode: .quickTimeCompatible, capabilities: verifiedCapabilities([.libx265])))
        XCTAssertThrowsError(try planner.validate(output: media(codec: "hevc", tag: "hev1"), source: media(codec: "vp9"), mode: .quickTimeCompatible))
    }

    func testValidationRejectsMissingAudioDimensionsTimingAndColorChanges() throws {
        let source = try media(codec: "vp9")
        for output in [
            try media(codec: "hevc", audio: nil),
            try media(codec: "hevc", width: 1920),
            try media(codec: "hevc", duration: "1"),
            try media(codec: "hevc", transfer: "unknown"),
            try media(codec: "hevc", frames: "12"),
            try media(codec: "hevc", format: "matroska,webm")
        ] {
            XCTAssertThrowsError(try planner.validate(output: output, source: source, mode: .quickTimeCompatible))
        }
    }

    func testRotatedVFRAndCoverArtDoNotChangePrimaryVideo() throws {
        var video = videoStream(codec: "h264")
        video["side_data_list"] = [["side_data_type": "Display Matrix", "rotation": 90]]
        video["avg_frame_rate"] = "47/2"
        video["r_frame_rate"] = "30/1"
        var cover = videoStream(codec: "mjpeg")
        cover["index"] = 2
        cover["disposition"] = ["attached_pic": 1]
        let source = try decode([cover, video, audioStream("aac")])
        XCTAssertEqual(source.primaryVideo?.index, 0)
        XCTAssertEqual(source.primaryVideo?.displayWidth, 2160)
        let plan = try planner.plan(media: source, mode: .quickTimeCompatible, capabilities: .init())
        let args = plan.arguments(input: URL(fileURLWithPath: "/tmp/in"), output: URL(fileURLWithPath: "/tmp/out"))
        XCTAssertTrue(args.contains("0:2"))
        XCTAssertTrue(args.contains("-noautorotate"))
        try planner.validate(output: source, source: source, mode: .quickTimeCompatible)
        XCTAssertThrowsError(try planner.validate(output: media(), source: source, mode: .quickTimeCompatible))
    }

    func testMalformedEmptyAndUnsupportedPixelDataFailClosed() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(ProbedMedia.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try planner.plan(media: decode([]), mode: .quickTimeCompatible, capabilities: .init()))
        XCTAssertThrowsError(try planner.plan(media: media(pixel: "yuv444p"), mode: .quickTimeCompatible, capabilities: .init()))
        XCTAssertThrowsError(try planner.plan(media: media(width: 0), mode: .originalEncoding, capabilities: .init()))
    }

    func testUnknownHDRMetadataAndMalformedTimingFailClosed() throws {
        var video = videoStream(codec: "hevc")
        video["pix_fmt"] = "yuv420p10le"
        video["color_transfer"] = "smpte2084"
        video["color_primaries"] = "bt2020"
        video["color_space"] = "bt2020nc"
        video["side_data_list"] = [["side_data_type": "DOVI configuration record", "dv_profile": 5]]
        XCTAssertThrowsError(try planner.plan(media: decode([video]), mode: .quickTimeCompatible, capabilities: .init()))

        var invalidTiming = videoStream(codec: "h264")
        invalidTiming["duration"] = "nan"
        XCTAssertThrowsError(try planner.plan(media: decode([invalidTiming]), mode: .quickTimeCompatible, capabilities: .init()))
        var invalidRotation = videoStream(codec: "h264")
        invalidRotation["tags"] = ["rotate": "broken"]
        XCTAssertThrowsError(try planner.plan(media: decode([invalidRotation]), mode: .quickTimeCompatible, capabilities: .init()))
        var missingRate = videoStream(codec: "h264")
        missingRate.removeValue(forKey: "avg_frame_rate")
        XCTAssertThrowsError(try planner.validate(output: decode([missingRate, audioStream("aac")]), source: media(), mode: .quickTimeCompatible))
    }

    func testVFRRemuxMayReportDifferentAverageRateWithoutChangingFrames() throws {
        var source = videoStream(codec: "h264")
        source["nb_frames"] = "38"
        var output = source
        output["avg_frame_rate"] = "19/1"
        try planner.validate(output: decode([output]), source: decode([source]), mode: .quickTimeCompatible)
    }

    func testSubtitlesAndArtworkAreExplicitlyMappedAndValidated() throws {
        let subtitle: [String: Any] = ["index": 3, "codec_type": "subtitle", "codec_name": "subrip", "tags": ["language": "jpn"]]
        let source = try decode([videoStream(codec: "h264"), audioStream("aac"), subtitle])
        let plan = try planner.plan(media: source, mode: .quickTimeCompatible, capabilities: .init())
        XCTAssertTrue(plan.arguments(input: URL(fileURLWithPath: "/tmp/in"), output: URL(fileURLWithPath: "/tmp/out")).contains("mov_text"))
        XCTAssertThrowsError(try planner.validate(output: media(), source: source, mode: .quickTimeCompatible))
    }

    func testInvalidAudioAndChangedArtworkFailValidation() throws {
        var audio = audioStream("aac")
        audio["channels"] = 0
        XCTAssertThrowsError(try planner.plan(media: decode([videoStream(codec: "h264"), audio]), mode: .quickTimeCompatible, capabilities: .init()))
        var cover = videoStream(codec: "mjpeg")
        cover["index"] = 2
        cover["disposition"] = ["attached_pic": 1]
        let source = try decode([videoStream(codec: "h264"), cover])
        cover["width"] = 1
        XCTAssertThrowsError(try planner.validate(output: decode([videoStream(codec: "h264"), cover]), source: source, mode: .quickTimeCompatible))
    }

    private func verifiedCapabilities(_ encoders: [MP4VideoEncoder]) throws -> MP4EncoderCapabilities {
        var capabilities = MP4EncoderCapabilities()
        for encoder in encoders {
            try capabilities.recordProbe(encoder: encoder, exitCode: 0, source: media(codec: "vp9"), output: media(codec: "hevc"))
        }
        return capabilities
    }

    private func videoStream(codec: String) -> [String: Any] {
        ["index": 0, "codec_type": "video", "codec_name": codec, "codec_tag_string": codec == "hevc" ? "hvc1" : "avc1",
         "width": 3840, "height": 2160, "pix_fmt": "yuv420p", "sample_aspect_ratio": "1:1",
         "color_space": "bt709", "color_transfer": "bt709", "color_primaries": "bt709", "color_range": "tv",
         "avg_frame_rate": "24/1", "r_frame_rate": "24/1", "duration": "2.0", "nb_frames": "48"]
    }

    private func audioStream(_ codec: String) -> [String: Any] {
        ["index": 1, "codec_type": "audio", "codec_name": codec, "channels": 2, "sample_rate": "48000"]
    }

    private func media(codec: String = "h264", audio: String? = "aac", pixel: String = "yuv420p", tag: String? = nil,
                       transfer: String = "bt709", primaries: String = "bt709", space: String = "bt709",
                       width: Int = 3840, duration: String = "2.0", frames: String = "48", format: String = "mov,mp4,m4a,3gp,3g2,mj2") throws -> ProbedMedia {
        var video = videoStream(codec: codec)
        video["pix_fmt"] = pixel
        video["codec_tag_string"] = tag ?? (codec == "hevc" ? "hvc1" : "avc1")
        video["color_transfer"] = transfer
        video["color_primaries"] = primaries
        video["color_space"] = space
        video["width"] = width
        video["duration"] = duration
        video["nb_frames"] = frames
        return try decode([video] + (audio.map { [audioStream($0)] } ?? []), format: format)
    }

    private func decode(_ streams: [[String: Any]], format: String = "mov,mp4,m4a,3gp,3g2,mj2") throws -> ProbedMedia {
        try JSONDecoder().decode(ProbedMedia.self, from: JSONSerialization.data(withJSONObject: ["streams": streams, "format": ["format_name": format, "duration": "2.0"]]))
    }
}
