import Foundation
import XCTest
@testable import YTDownloaderPro2

final class UpdateCheckerTests: XCTestCase {
    func testContentsAPIResponseFindsNewMacOSRelease() async throws {
        let checker = try makeChecker(latestVersion: "2.0.1")

        let result = await checker.check(manual: true)

        guard case let .available(manifest) = result else {
            return XCTFail("Expected an available macOS update, got \(result)")
        }
        XCTAssertEqual(manifest.latestVersion, "2.0.1")
        XCTAssertEqual(manifest.releaseNotes, "Example manifest only; not a release.")
    }

    func testMacAppRejectsWindowsManifest() async throws {
        let checker = try makeChecker(platform: "windows")

        let result = await checker.check(manual: true)
        XCTAssertEqual(result, .failed(.wrongPlatformManifest))
    }

    func testSemanticVersionImplementsSemVerPrecedenceAndIgnoresBuildMetadata() throws {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0"
        ]
        let parsed = try ordered.map { try XCTUnwrap(SemanticVersion($0)) }

        XCTAssertEqual(parsed.sorted(), parsed)
        XCTAssertEqual(SemanticVersion("1.0.0+build.1"), SemanticVersion("1.0.0+build.2"))
    }

    func testSemanticVersionComparesArbitrarilyLargeNumericIdentifiers() throws {
        let hugeMajor = try XCTUnwrap(SemanticVersion("999999999999999999999999.0.0"))
        let ordinaryMajor = try XCTUnwrap(SemanticVersion("2.0.0"))
        let hugePrerelease = try XCTUnwrap(SemanticVersion("1.0.0-999999999999999999999999"))
        let ordinaryPrerelease = try XCTUnwrap(SemanticVersion("1.0.0-2"))

        XCTAssertGreaterThan(hugeMajor, ordinaryMajor)
        XCTAssertGreaterThan(hugePrerelease, ordinaryPrerelease)
    }

    func testSemanticVersionRejectsMalformedOrLeadingZeroVersions() async throws {
        for version in ["2", "2.0", "02.0.0", "2.00.0", "2.0.01", "2.0.0-01", "2.0.0+", "2١.0.0"] {
            let checker = try makeChecker(latestVersion: version)

            let result = await checker.check(manual: true)

            XCTAssertEqual(result, .failed(.invalidVersion), "version: \(version)")
        }
    }

    func testPrereleaseDoesNotReplaceMatchingReleaseButNewPatchDoes() async throws {
        let prerelease = try makeChecker(currentVersion: "2.0.0", latestVersion: "2.0.0-rc.1")
        let patch = try makeChecker(currentVersion: "2.0.0", latestVersion: "2.0.1-alpha.1")

        let prereleaseResult = await prerelease.check(manual: true)
        let patchResult = await patch.check(manual: true)
        XCTAssertEqual(prereleaseResult, .upToDate)
        XCTAssertTrue(patchResult.isAvailable)
    }

    func testManifestRequiresHTTPSReleaseAndDownloadURLs() async throws {
        for field in ["release_url", "download_url"] {
            var manifest = validManifest()
            manifest[field] = "http://downloads.example.invalid/file"
            let checker = try makeChecker(manifest: manifest)

            let result = await checker.check(manual: true)
            XCTAssertEqual(result, .failed(.insecureURL), "field: \(field)")
        }
    }

    func testManifestRequiresLowercaseSHA256() async throws {
        for checksum in [
            String(repeating: "a", count: 63),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
            String(repeating: "1", count: 63) + "١"
        ] {
            var manifest = validManifest()
            manifest["sha256"] = checksum
            let checker = try makeChecker(manifest: manifest)

            let result = await checker.check(manual: true)
            XCTAssertEqual(result, .failed(.invalidChecksum), "checksum: \(checksum)")
        }
    }

    func testMinimumMacOSMustBeSemVerAndReportsUnsupportedOS() async throws {
        var invalidManifest = validManifest()
        invalidManifest["minimum_macos"] = "13"
        let invalid = try makeChecker(manifest: invalidManifest)
        let unsupported = try makeChecker(currentMacOSVersion: "13.6.0", minimumMacOS: "14.0.0")

        let invalidResult = await invalid.check(manual: true)
        XCTAssertEqual(invalidResult, .failed(.invalidMinimumMacOS))
        guard case let .unsupportedOS(manifest) = await unsupported.check(manual: true) else {
            return XCTFail("Expected unsupported OS result")
        }
        XCTAssertEqual(manifest.minimumMacOS, "14.0.0")
    }

    func testMalformedContentsEnvelopeAndManifestFailClosed() async throws {
        let wrongEncoding = try makeChecker(contentsEnvelope: ["encoding": "utf-8", "content": "e30="])
        let malformedBase64 = try makeChecker(contentsEnvelope: ["encoding": "base64", "content": "not base64!"])
        let malformedManifest = try makeChecker(manifestData: Data("not-json".utf8))

        let wrongEncodingResult = await wrongEncoding.check(manual: true)
        let malformedBase64Result = await malformedBase64.check(manual: true)
        let malformedManifestResult = await malformedManifest.check(manual: true)
        XCTAssertEqual(wrongEncodingResult, .failed(.invalidManifest))
        XCTAssertEqual(malformedBase64Result, .failed(.invalidManifest))
        XCTAssertEqual(malformedManifestResult, .failed(.invalidManifest))
    }

    func testNonSuccessHTTPResponseIsTransientOnlyForAutomaticCheck() async throws {
        let automatic = try makeChecker(statusCode: 503)
        let manual = try makeChecker(statusCode: 503)

        let automaticResult = await automatic.check(manual: false)
        let manualResult = await manual.check(manual: true)
        XCTAssertEqual(automaticResult, .failed(.silentTransient))
        XCTAssertEqual(manualResult, .failed(.actionableNetwork))
    }

    func testAutomaticTransientFailureIsSilentButManualIsActionable() async throws {
        let automatic = makeChecker(error: URLError(.timedOut))
        let manual = makeChecker(error: URLError(.timedOut))

        let automaticResult = await automatic.check(manual: false)
        let manualResult = await manual.check(manual: true)
        XCTAssertEqual(automaticResult, .failed(.silentTransient))
        XCTAssertEqual(manualResult, .failed(.actionableNetwork))
    }

    func testNonTransientTransportFailureRemainsActionableForAutomaticCheck() async throws {
        let checker = makeChecker(error: URLError(.serverCertificateUntrusted))

        let result = await checker.check(manual: false)
        XCTAssertEqual(result, .failed(.actionableNetwork))
    }

    func testLiveCheckerFailsClosedWhenBundleVersionIsMissing() async throws {
        let bundle = Bundle(for: UpdateCheckerTests.self)
        XCTAssertNil(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        let data = try contentsData(for: validManifest())
        let response = try XCTUnwrap(HTTPURLResponse(
            url: UpdateChecker.publicManifestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        let checker = UpdateChecker.live(
            bundle: bundle,
            session: StubUpdateSession(data: data, response: response)
        )

        let result = await checker.check(manual: true)
        XCTAssertEqual(result, .failed(.invalidVersion))
    }

    func testFinalResponseURLMustRemainHTTPSOnRequestedOriginAndPath() async throws {
        let rejectedURLs = [
            "http://api.github.com/repos/example/YT-Downloader-Pro/contents/updates/macos.json",
            "https://downloads.example.invalid/repos/example/YT-Downloader-Pro/contents/updates/macos.json",
            "https://api.github.com/repos/example/YT-Downloader-Pro/contents/updates/windows.json"
        ]

        for source in rejectedURLs {
            let checker = try makeChecker(responseURL: try XCTUnwrap(URL(string: source)))
            let result = await checker.check(manual: true)
            XCTAssertEqual(
                result,
                .failed(.invalidResponse),
                "final URL: \(source)"
            )
        }
    }

    func testContentsResponseAndDecodedManifestHaveSmallBounds() async throws {
        XCTAssertLessThanOrEqual(UpdateChecker.maximumResponseBytes, 256 * 1_024)
        XCTAssertLessThan(UpdateChecker.maximumDecodedManifestBytes, UpdateChecker.maximumResponseBytes)

        let oversizedResponse = Data(repeating: 0x20, count: UpdateChecker.maximumResponseBytes + 1)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: manifestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let responseChecker = UpdateChecker(
            manifestURL: manifestURL,
            currentVersion: "2.0.0",
            currentMacOSVersion: "13.6.0",
            session: StubUpdateSession(data: oversizedResponse, response: response)
        )

        var manifest = validManifest()
        manifest["release_notes"] = String(
            repeating: "x",
            count: UpdateChecker.maximumDecodedManifestBytes
        )
        let decodedChecker = try makeChecker(manifest: manifest)

        let responseResult = await responseChecker.check(manual: true)
        let decodedResult = await decodedChecker.check(manual: true)
        XCTAssertEqual(responseResult, .failed(.invalidResponse))
        XCTAssertEqual(decodedResult, .failed(.invalidManifest))
    }

    func testChunkedOversizedResponseStopsAtFirstByteOverLimit() async throws {
        let body = TestUpdateResponseBody(chunks: [
            Data(repeating: 0x20, count: UpdateChecker.maximumResponseBytes / 2),
            Data(repeating: 0x20, count: UpdateChecker.maximumResponseBytes / 2),
            Data([0x20]),
            Data(repeating: 0x20, count: 1_024)
        ])
        let checker = try makeChecker(body: body)

        let result = await checker.check(manual: true)

        XCTAssertEqual(result, .failed(.invalidResponse))
        XCTAssertEqual(body.requestCount, 3)
        XCTAssertTrue(body.isCancelled)
    }

    func testStreamingResponseAllowsExactLimitAndRejectsLimitPlusOne() async throws {
        let exactBody = TestUpdateResponseBody(
            chunks: [Data(repeating: 0x20, count: UpdateChecker.maximumResponseBytes)]
        )
        let oversizedBody = TestUpdateResponseBody(chunks: [
            Data(repeating: 0x20, count: UpdateChecker.maximumResponseBytes),
            Data([0x20])
        ])
        let exactChecker = try makeChecker(body: exactBody)
        let oversizedChecker = try makeChecker(body: oversizedBody)

        let exactResult = await exactChecker.check(manual: true)
        let oversizedResult = await oversizedChecker.check(manual: true)

        XCTAssertEqual(exactResult, .failed(.invalidManifest))
        XCTAssertFalse(exactBody.isCancelled)
        XCTAssertEqual(oversizedResult, .failed(.invalidResponse))
        XCTAssertTrue(oversizedBody.isCancelled)
    }

    func testInvalidHTTPMetadataCancelsBeforeBodyConsumption() async throws {
        let body = TestUpdateResponseBody(chunks: [Data("unused".utf8)])
        let responseURL = try XCTUnwrap(
            URL(string: "https://downloads.example.invalid/updates/macos.json")
        )
        let response = try XCTUnwrap(HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let checker = UpdateChecker(
            manifestURL: manifestURL,
            currentVersion: "2.0.0",
            currentMacOSVersion: "13.6.0",
            session: StubUpdateSession(body: body, response: response)
        )

        let result = await checker.check(manual: true)

        XCTAssertEqual(result, .failed(.invalidResponse))
        XCTAssertEqual(body.requestCount, 0)
        XCTAssertTrue(body.isCancelled)
    }

    func testOversizedDeclaredLengthCancelsBeforeBodyConsumption() async throws {
        let body = TestUpdateResponseBody(chunks: [Data("unused".utf8)])
        let checker = try makeChecker(
            body: body,
            headers: ["Content-Length": String(UpdateChecker.maximumResponseBytes + 1)]
        )

        let result = await checker.check(manual: true)

        XCTAssertEqual(result, .failed(.invalidResponse))
        XCTAssertEqual(body.requestCount, 0)
        XCTAssertTrue(body.isCancelled)
    }

    func testCancellingCheckCancelsStreamingTransport() async throws {
        let body = TestUpdateResponseBody(chunks: [], finishesAfterChunks: false)
        let checker = try makeChecker(body: body)
        let task = Task { await checker.check(manual: true) }
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            body.requestCount == 1
        }

        task.cancel()
        _ = await task.value

        XCTAssertTrue(body.isCancelled)
    }

    func testLiveBodyCancellationDiscardsAlreadyCompletedQueuedBytes() async throws {
        let scenario = StreamingURLProtocolScenario(
            chunks: [Data(repeating: 0x61, count: 1_024)],
            finishesAfterChunks: true
        )
        let response = try await liveStreamingResponse(scenario: scenario)

        response.body.cancel()

        await XCTAssertThrowsCancellationError {
            try await response.body.nextChunk()
        }
    }

    func testPreCancelledTaskCannotReadAlreadyCompletedQueuedLiveBytes() async throws {
        let scenario = StreamingURLProtocolScenario(
            chunks: [Data(repeating: 0x62, count: 1_024)],
            finishesAfterChunks: true
        )
        let response = try await liveStreamingResponse(scenario: scenario)
        let consumer = Task { () throws -> Data? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await response.body.nextChunk()
        }

        await XCTAssertThrowsCancellationError {
            try await awaitTaskValue(of: consumer, timeoutNanoseconds: 2_000_000_000)
        }
    }

    func testCollectRejectsChunkReturnedAfterNonCooperativeCancellation() async throws {
        let gate = AsyncGate()
        let body = NonCooperativeUpdateResponseBody(
            chunk: Data(repeating: 0x20, count: 32),
            gate: gate
        )
        let checker = try makeChecker(body: body)
        let task = Task { await checker.check(manual: true) }
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            body.requestCount == 1
        }

        task.cancel()
        await gate.open()
        let result = await task.value

        XCTAssertEqual(result, .failed(.invalidManifest))
        XCTAssertTrue(body.isCancelled)
        XCTAssertEqual(body.requestCount, 1)
    }

    func testLiveBodyCancellationResumesWaitingConsumerOnceAndInvalidatesSession() async throws {
        let scenario = StreamingURLProtocolScenario(chunks: [], finishesAfterChunks: false)
        let response = try await liveStreamingResponse(scenario: scenario)
        let completionCount = LockedCounter()
        let waiter = Task { () throws -> Data? in
            defer { completionCount.increment() }
            return try await response.body.nextChunk()
        }
        await Task.yield()

        response.body.cancel()
        response.body.cancel()

        await XCTAssertThrowsCancellationError {
            try await awaitTaskValue(of: waiter, timeoutNanoseconds: 2_000_000_000)
        }
        try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            scenario.stopCount == 1 && scenario.deinitializationCount == 1
        }
        XCTAssertEqual(completionCount.value, 1)
    }

    func testLiveCancellationRacingFirstResponseIsTerminalFor128Iterations() async throws {
        try await withDeadline(timeoutNanoseconds: 10_000_000_000) {
            for iteration in 0..<128 {
                let scenario = StreamingURLProtocolScenario(
                    chunks: [Data([UInt8(iteration % 255)])],
                    finishesAfterChunks: true,
                    sendsAutomatically: false
                )
                let gate = AsyncGate()
                let requestURL = StreamingURLProtocol.registry.makeURL()
                let transport = Self.liveStreamingTransport(scenario: scenario, url: requestURL)
                let consumer = Task { () throws -> Data? in
                    let response = try await transport.response(
                        for: URLRequest(url: requestURL),
                        maximumBytes: UpdateChecker.maximumResponseBytes
                    )
                    await gate.wait()
                    return try await response.body.nextChunk()
                }
                try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
                    scenario.hasStarted
                }

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { consumer.cancel() }
                    group.addTask { scenario.sendResponseAndChunks() }
                }
                await gate.open()

                do {
                    let chunk = try await awaitTaskValue(
                        of: consumer,
                        timeoutNanoseconds: 2_000_000_000
                    )
                    XCTFail("Cancelled iteration \(iteration) returned \(chunk?.count ?? 0) bytes")
                } catch is CancellationError {
                    continue
                }
            }
        }
    }

    func testStreamingTransportBoundaryIsSendable() {
        requireSendable(UpdateSessionResponse.self)
        requireSendable(URLSessionUpdateSession.self)
    }

    private func makeChecker(
        currentVersion: String = "2.0.0",
        currentMacOSVersion: String = "13.6.0",
        latestVersion: String = "2.0.1",
        platform: String = "macos",
        minimumMacOS: String = "13.0.0",
        statusCode: Int = 200,
        responseURL: URL? = nil
    ) throws -> UpdateChecker {
        var manifest = validManifest()
        manifest["latest_version"] = latestVersion
        manifest["platform"] = platform
        manifest["minimum_macos"] = minimumMacOS
        return try makeChecker(
            currentVersion: currentVersion,
            currentMacOSVersion: currentMacOSVersion,
            manifest: manifest,
            statusCode: statusCode,
            responseURL: responseURL
        )
    }

    private func liveStreamingResponse(
        scenario: StreamingURLProtocolScenario
    ) async throws -> UpdateSessionResponse {
        let url = StreamingURLProtocol.registry.makeURL()
        let transport = Self.liveStreamingTransport(scenario: scenario, url: url)
        return try await withDeadline(timeoutNanoseconds: 2_000_000_000) {
            try await transport.response(
                for: URLRequest(url: url),
                maximumBytes: UpdateChecker.maximumResponseBytes
            )
        }
    }

    private static func liveStreamingTransport(
        scenario: StreamingURLProtocolScenario,
        url: URL
    ) -> URLSessionUpdateSession {
        StreamingURLProtocol.registry.register(scenario, for: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        return URLSessionUpdateSession(configuration: configuration)
    }

    private func makeChecker(
        body: any UpdateResponseBody,
        statusCode: Int = 200,
        headers: [String: String]? = nil
    ) throws -> UpdateChecker {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: manifestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
        return UpdateChecker(
            manifestURL: manifestURL,
            currentVersion: "2.0.0",
            currentMacOSVersion: "13.6.0",
            session: StubUpdateSession(body: body, response: response)
        )
    }

    private func makeChecker(
        currentVersion: String = "2.0.0",
        currentMacOSVersion: String = "13.6.0",
        manifest: [String: Any],
        statusCode: Int = 200,
        responseURL: URL? = nil
    ) throws -> UpdateChecker {
        try makeChecker(
            currentVersion: currentVersion,
            currentMacOSVersion: currentMacOSVersion,
            manifestData: JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
            statusCode: statusCode,
            responseURL: responseURL
        )
    }

    private func makeChecker(
        currentVersion: String = "2.0.0",
        currentMacOSVersion: String = "13.6.0",
        manifestData: Data,
        statusCode: Int = 200,
        responseURL: URL? = nil
    ) throws -> UpdateChecker {
        let envelope: [String: Any] = [
            "encoding": "base64",
            "content": manifestData.base64EncodedString()
        ]
        return try makeChecker(
            currentVersion: currentVersion,
            currentMacOSVersion: currentMacOSVersion,
            contentsEnvelope: envelope,
            statusCode: statusCode,
            responseURL: responseURL
        )
    }

    private func makeChecker(
        currentVersion: String = "2.0.0",
        currentMacOSVersion: String = "13.6.0",
        contentsEnvelope: [String: Any],
        statusCode: Int = 200,
        responseURL: URL? = nil
    ) throws -> UpdateChecker {
        let data = try JSONSerialization.data(withJSONObject: contentsEnvelope, options: [.sortedKeys])
        let response = try XCTUnwrap(HTTPURLResponse(
            url: responseURL ?? manifestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return UpdateChecker(
            manifestURL: manifestURL,
            currentVersion: currentVersion,
            currentMacOSVersion: currentMacOSVersion,
            session: StubUpdateSession(data: data, response: response)
        )
    }

    private func contentsData(for manifest: [String: Any]) throws -> Data {
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        return try JSONSerialization.data(
            withJSONObject: [
                "encoding": "base64",
                "content": manifestData.base64EncodedString()
            ],
            options: [.sortedKeys]
        )
    }

    private func makeChecker(error: URLError) -> UpdateChecker {
        UpdateChecker(
            manifestURL: manifestURL,
            currentVersion: "2.0.0",
            currentMacOSVersion: "13.6.0",
            session: StubUpdateSession(error: error)
        )
    }

    private func validManifest() -> [String: Any] {
        [
            "schema_version": 1,
            "platform": "macos",
            "latest_version": "2.0.1",
            "minimum_macos": "13.0.0",
            "release_url": "https://example.invalid/releases/macos-example",
            "download_url": "https://example.invalid/YT-Downloader-Pro-macOS-universal-example.zip",
            "sha256": String(repeating: "0", count: 64),
            "published_at": "2026-08-18T00:00:00Z",
            "release_notes": "Example manifest only; not a release."
        ]
    }

    private var manifestURL: URL {
        URL(string: "https://api.github.com/repos/example/YT-Downloader-Pro/contents/updates/macos.json?ref=main")!
    }
}

private actor StubUpdateSession: UpdateSession {
    private let body: (any UpdateResponseBody)?
    private let response: HTTPURLResponse?
    private let error: URLError?

    init(data: Data, response: HTTPURLResponse) {
        body = TestUpdateResponseBody(chunks: [data])
        self.response = response
        error = nil
    }

    init(body: any UpdateResponseBody, response: HTTPURLResponse) {
        self.body = body
        self.response = response
        error = nil
    }

    init(error: URLError) {
        body = nil
        response = nil
        self.error = error
    }

    func response(for request: URLRequest, maximumBytes: Int) async throws -> UpdateSessionResponse {
        if let error { throw error }
        guard let body, let response else { throw URLError(.unknown) }
        return UpdateSessionResponse(response: response, body: body)
    }
}

private final class TestUpdateResponseBody: UpdateResponseBody, @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationProbe: CancellationProbe
    private let body: StreamingUpdateResponseBody
    private var requested = 0

    init(chunks: [Data], finishesAfterChunks: Bool = true) {
        let cancellationProbe = CancellationProbe()
        self.cancellationProbe = cancellationProbe
        body = StreamingUpdateResponseBody {
            cancellationProbe.recordCancellation()
        }
        chunks.forEach { body.yield($0) }
        if finishesAfterChunks {
            body.finish()
        }
    }

    var requestCount: Int {
        lock.withLock { requested }
    }

    var isCancelled: Bool {
        cancellationProbe.count > 0
    }

    func nextChunk() async throws -> Data? {
        lock.withLock { requested += 1 }
        return try await body.nextChunk()
    }

    func cancel() {
        body.cancel()
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    var count: Int { lock.withLock { cancellations } }
    func recordCancellation() { lock.withLock { cancellations += 1 } }
}

private final class NonCooperativeUpdateResponseBody: UpdateResponseBody, @unchecked Sendable {
    private let lock = NSLock()
    private let chunk: Data
    private let gate: AsyncGate
    private var requests = 0
    private var delivered = false
    private var cancelled = false

    init(chunk: Data, gate: AsyncGate) {
        self.chunk = chunk
        self.gate = gate
    }

    var requestCount: Int { lock.withLock { requests } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func nextChunk() async throws -> Data? {
        lock.withLock { requests += 1 }
        await gate.wait()
        return lock.withLock {
            guard !delivered else { return nil }
            delivered = true
            return chunk
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private func requireSendable<T: Sendable>(_: T.Type) {}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = StreamingURLProtocolRegistry()
    private var scenario: StreamingURLProtocolScenario?

    override class func canInit(with request: URLRequest) -> Bool {
        registry.contains(request.url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let scenario = Self.registry.scenario(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        self.scenario = scenario
        scenario.didStart(self)
    }

    override func stopLoading() {
        scenario?.didStop()
    }

    deinit {
        scenario?.didDeinitialize()
    }
}

private final class StreamingURLProtocolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [URL: StreamingURLProtocolScenario] = [:]
    private var nextIdentifier = 0

    func makeURL() -> URL {
        lock.withLock {
            defer { nextIdentifier += 1 }
            return URL(
                string: "https://api.github.com/repos/example/YT-Downloader-Pro/contents/updates/macos.json?fixture=\(nextIdentifier)"
            )!
        }
    }

    func register(_ scenario: StreamingURLProtocolScenario, for url: URL) {
        lock.withLock { scenarios[url] = scenario }
    }

    func contains(_ url: URL?) -> Bool {
        lock.withLock { url.flatMap { scenarios[$0] } != nil }
    }

    func scenario(for url: URL?) -> StreamingURLProtocolScenario? {
        lock.withLock { url.flatMap { scenarios[$0] } }
    }
}

private final class StreamingURLProtocolScenario: @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [Data]
    private let finishesAfterChunks: Bool
    private let sendsAutomatically: Bool
    private weak var urlProtocol: StreamingURLProtocol?
    private var started = false
    private var stopped = 0
    private var deinitialized = 0

    init(
        chunks: [Data],
        finishesAfterChunks: Bool,
        sendsAutomatically: Bool = true
    ) {
        self.chunks = chunks
        self.finishesAfterChunks = finishesAfterChunks
        self.sendsAutomatically = sendsAutomatically
    }

    var hasStarted: Bool { lock.withLock { started } }
    var stopCount: Int { lock.withLock { stopped } }
    var deinitializationCount: Int { lock.withLock { deinitialized } }

    func didStart(_ urlProtocol: StreamingURLProtocol) {
        lock.withLock {
            self.urlProtocol = urlProtocol
            started = true
        }
        if sendsAutomatically {
            sendResponseAndChunks()
        }
    }

    func didStop() {
        lock.withLock { stopped += 1 }
    }

    func didDeinitialize() {
        lock.withLock { deinitialized += 1 }
    }

    func sendResponseAndChunks() {
        guard let urlProtocol = lock.withLock({ self.urlProtocol }) else { return }
        let response = HTTPURLResponse(
            url: urlProtocol.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        urlProtocol.client?.urlProtocol(
            urlProtocol,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        for chunk in chunks {
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: chunk)
        }
        if finishesAfterChunks {
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct TestDeadlineExceeded: Error {}

private func awaitTaskValue<T: Sendable>(
    of task: Task<T, Error>,
    timeoutNanoseconds: UInt64
) async throws -> T {
    try await withDeadline(timeoutNanoseconds: timeoutNanoseconds) {
        try await task.value
    }
}

private func withDeadline<T: Sendable>(
    timeoutNanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw TestDeadlineExceeded()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64,
    condition: @escaping @Sendable () -> Bool
) async throws {
    try await withDeadline(timeoutNanoseconds: timeoutNanoseconds) {
        while !condition() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private func XCTAssertThrowsCancellationError(
    _ operation: () async throws -> some Sendable,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected CancellationError", file: file, line: line)
    } catch is CancellationError {
        return
    } catch {
        XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
    }
}
