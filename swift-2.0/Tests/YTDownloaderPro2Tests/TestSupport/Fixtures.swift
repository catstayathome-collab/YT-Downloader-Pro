import Foundation
@testable import YTDownloaderPro2

extension DownloadOptions {
    static func fixture(
        outputKind: OutputKind = .mp4,
        videoQuality: VideoQuality = .best,
        audioQuality: AudioQuality = .best,
        cookies: CookieMode = .none
    ) -> DownloadOptions {
        DownloadOptions(
            outputKind: outputKind,
            videoQuality: videoQuality,
            audioQuality: audioQuality,
            cookies: cookies
        )
    }
}

extension DownloadJob {
    static func fixture(
        id: UUID = UUID(),
        sourceURL: String = "https://example.com/video",
        title: String = "Example video",
        status: DownloadStatus = .queued,
        outputKind: OutputKind = .mp4,
        cookies: CookieMode = .none,
        retryCount: Int = 0,
        awaitsBatchAnalysis: Bool = false,
        outputURL: URL? = URL(fileURLWithPath: "/tmp/Example video.mp4")
    ) -> DownloadJob {
        DownloadJob(
            id: id,
            sourceURL: sourceURL,
            title: title,
            status: status,
            outputURL: outputURL,
            options: .fixture(outputKind: outputKind, cookies: cookies),
            retryCount: retryCount,
            awaitsBatchAnalysis: awaitsBatchAnalysis
        )
    }

    static func fixtures(count: Int) -> [DownloadJob] {
        (0..<count).map { index in
            fixture(title: "Example video \(index + 1)")
        }
    }
}

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func collect<Sequence: AsyncSequence>(_ sequence: Sequence) async throws -> [Sequence.Element] {
    var elements: [Sequence.Element] = []
    for try await element in sequence {
        elements.append(element)
    }
    return elements
}

func analysisFixtureData(named name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
        throw NSError(domain: "Fixtures", code: 1)
    }
    return try Data(contentsOf: url)
}
