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
    private let data: Data?
    private let response: URLResponse?
    private let error: URLError?

    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
        error = nil
    }

    init(error: URLError) {
        data = nil
        response = nil
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error { throw error }
        return (try XCTUnwrap(data), try XCTUnwrap(response))
    }
}
