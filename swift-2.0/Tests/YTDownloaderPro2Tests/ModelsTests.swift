import XCTest
@testable import YTDownloaderPro2

final class ModelsTests: XCTestCase {
    func testDefaultsUseBestQualityAndFiveWorkers() {
        XCTAssertEqual(DownloadOptions.defaults.videoQuality, .best)
        XCTAssertEqual(DownloadOptions.defaults.audioQuality, .best)
        XCTAssertEqual(AppSettings.defaults.maximumConcurrentDownloads, 5)
    }

    func testConcurrencyClampsToSupportedRange() {
        XCTAssertEqual(AppSettings(maximumConcurrentDownloads: 0).maximumConcurrentDownloads, 1)
        XCTAssertEqual(AppSettings(maximumConcurrentDownloads: 99).maximumConcurrentDownloads, 10)
    }

    func testSettingsDefaultsIncludeFuturePreferences() {
        XCTAssertNil(AppSettings.defaults.languageOverride)
        XCTAssertEqual(AppSettings.defaults.defaultOptions, .defaults)
        XCTAssertTrue(AppSettings.defaults.automaticallyCheckForUpdates)
    }

    func testMergingCannotPause() {
        XCTAssertFalse(DownloadStatus.merging.canPause)

        var job = DownloadJob.fixture(status: .merging)

        XCTAssertThrowsError(try job.transition(to: .paused))
    }

    func testTerminalJobsCannotReturnToActiveStatus() {
        var job = DownloadJob.fixture(status: .completed)

        XCTAssertThrowsError(try job.transition(to: .downloading))
    }

    func testQueuedJobCannotCompleteWithoutRunning() {
        var job = DownloadJob.fixture(status: .queued)

        XCTAssertThrowsError(try job.transition(to: .completed))
    }

    func testSidebarMappingMatchesDesign() {
        XCTAssertEqual(DownloadStatus.queued.sidebarSection, .running)
        XCTAssertEqual(DownloadStatus.cancelled.sidebarSection, .stopped)
        XCTAssertEqual(DownloadStatus.failed.sidebarSection, .failed)
    }

    func testDownloadFailureCanBeThrownAndCaughtAsError() {
        let failure = DownloadFailure(category: .networkUnavailable)

        func throwFailure() throws {
            throw failure
        }

        XCTAssertThrowsError(try throwFailure()) { error in
            XCTAssertEqual(error as? DownloadFailure, failure)
        }
    }

    func testDownloadFailureRedactsSensitiveDiagnosticValues() throws {
        let failure = DownloadFailure(
            category: .unknown,
            technicalDetail: """
            HTTP 403 for https://example.com/watch?v=public&format=best&sig=url-signature&token=url-token; \
            cookie=session=browser-secret; Authorization: Bearer authorization-secret; \
            access-token=access-secret; PO-token: po-secret
            """
        )

        let detail = try XCTUnwrap(failure.technicalDetail)

        XCTAssertFalse(detail.contains("browser-secret"))
        XCTAssertFalse(detail.contains("authorization-secret"))
        XCTAssertFalse(detail.contains("access-secret"))
        XCTAssertFalse(detail.contains("po-secret"))
        XCTAssertFalse(detail.contains("url-signature"))
        XCTAssertFalse(detail.contains("url-token"))
        XCTAssertTrue(detail.contains("HTTP 403"))
        XCTAssertTrue(detail.contains("v="))
        XCTAssertTrue(detail.contains("format="))
        XCTAssertTrue(detail.contains("[REDACTED]"))
    }

    func testClassifiedFailureTechnicalDetailUsesCompleteTask9RedactionCorpus() throws {
        let stderr = """
        ERROR: HTTP Error 403: Forbidden
        Loading cookies from /Users/example/Library/Cookies/private-cookies.txt
        Request https://url-user:url-password@media.test/watch?v=query-value&list=playlist-value#url-fragment
        Proxy tunnel: socks5://detail-user:detail-password@proxy.test:1080/path?token=detail-query#detail-fragment
        Command output: yt-dlp -u output-user -p output-password -2 output-twofactor \
        -uattached-user -pattached-password -2attached-twofactor \
        --username=long-user --password long-password \
        --cookies "/Users/example/Library/Application Support/browser/cookies.sqlite" \
        --cookies-from-browser="chrome:Profile 1" \
        --proxy https://proxy-user:proxy-password@proxy.test:8443/tunnel?session=proxy-query#proxy-fragment \
        --geo-verification-proxy=socks5://geo-user:geo-password@geo-proxy.test:1080?route=geo-query#geo-fragment \
        --http-header "Authorization: Bearer header-secret"
        Cookie: SID=browser-secret
        Credentials username=prose-user password: prose-password; bearer bearer-secret
        """

        let failure = DownloadFailure.classify(stderr: stderr, context: .download)
        let detail = try XCTUnwrap(failure.technicalDetail)

        XCTAssertEqual(failure.category, .clientValidationFailed)
        for secret in [
            "private-cookies.txt", "url-user", "url-password", "query-value", "playlist-value", "url-fragment",
            "detail-user", "detail-password", "detail-query", "detail-fragment",
            "output-user", "output-password", "output-twofactor", "attached-user", "attached-password",
            "attached-twofactor", "long-user", "long-password", "cookies.sqlite", "Profile 1",
            "proxy-user", "proxy-password", "proxy-query", "proxy-fragment",
            "geo-user", "geo-password", "geo-query", "geo-fragment", "header-secret", "browser-secret",
            "prose-user", "prose-password", "bearer-secret"
        ] {
            XCTAssertFalse(detail.contains(secret), "Classified failure leaked \(secret)")
        }
        XCTAssertTrue(detail.contains("HTTP Error 403"))
        XCTAssertTrue(detail.contains("media.test/watch"))
        XCTAssertTrue(detail.contains("v="))
        XCTAssertTrue(detail.contains("list="))
        XCTAssertTrue(detail.contains("[REDACTED]"))
    }

    func testDecodingPersistedFailureSanitizesLegacyTechnicalDetailAtModelBoundary() throws {
        let safe = DownloadFailure(category: .networkUnavailable, technicalDetail: "placeholder")
        let encoded = try JSONEncoder().encode(safe)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["technicalDetail"] = "Loading cookies from /Users/example/private.txt; https://user:password@example.test/watch?token=secret#fragment"
        object["summaryKey"] = "raw-helper-summary-secret"
        object["recoverySuggestionKey"] = "raw-helper-recovery-secret"
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DownloadFailure.self, from: legacyData)
        let detail = try XCTUnwrap(decoded.technicalDetail)

        for secret in ["private.txt", "user", "password", "secret", "fragment"] {
            XCTAssertFalse(detail.contains(secret), "Decoded failure leaked \(secret)")
        }
        XCTAssertTrue(detail.contains("example.test/watch"))
        XCTAssertTrue(detail.contains("[REDACTED]"))
        XCTAssertEqual(decoded.summaryKey, DownloadFailure.Category.networkUnavailable.summaryKey)
        XCTAssertEqual(decoded.recoverySuggestionKey, DownloadFailure.Category.networkUnavailable.recoveryKey)
    }

    func testLegacyJobWithoutTitleSourceDefaultsToRealMetadataSemantics() throws {
        let job = DownloadJob.fixture(title: "Untitled video")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "titleSource")

        let restored = try JSONDecoder().decode(
            DownloadJob.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(restored.titleSource)
        XCTAssertEqual(
            MediaFallbackText.localized(restored.title, source: restored.titleSource, locale: Locale(identifier: "ja")),
            "Untitled video"
        )
    }

    func testDownloadFailureRedactsEveryCookieHeaderValue() throws {
        let failure = DownloadFailure(
            category: .unknown,
            technicalDetail: "Cookie: SID=secret-one; HSID=secret-two\nSafe context: retrying request"
        )

        let detail = try XCTUnwrap(failure.technicalDetail)

        XCTAssertFalse(detail.contains("secret-one"))
        XCTAssertFalse(detail.contains("secret-two"))
        XCTAssertTrue(detail.contains("Safe context: retrying request"))
    }

    func testDownloadFailureRedactsAuthorizationHeaderWithoutRemovingNextLine() throws {
        let failure = DownloadFailure(
            category: .unknown,
            technicalDetail: "Authorization: Bearer authorization-secret\nSafe context: HTTP 403"
        )

        let detail = try XCTUnwrap(failure.technicalDetail)

        XCTAssertFalse(detail.contains("authorization-secret"))
        XCTAssertTrue(detail.contains("Safe context: HTTP 403"))
    }

    func testDiagnosticDetailRedactsStructuredURLsFlagsAndProseWithoutDroppingContext() {
        let detail = DownloadFailure.sanitizedDiagnosticDetail("""
        Request https://url-user:url-password@example.test/watch?v=secret&list=private#fragment-secret failed
        Loading cookies from /Users/example/private/cookies.txt
        Command yt-dlp -u short-user -p short-password --password=long-password
        Proxy socks5://proxy-user:proxy-password@proxy.test:1080/path?route=secret-route#secret-fragment
        Authorization material bearer bearer-secret
        Safe context: HTTP 403 retry 2
        """)

        for secret in [
            "url-user", "url-password", "secret", "private", "fragment-secret", "cookies.txt",
            "short-user", "short-password", "long-password", "proxy-user", "proxy-password",
            "secret-route", "secret-fragment", "bearer-secret"
        ] {
            XCTAssertFalse(detail.contains(secret), "Sanitized detail leaked \(secret)")
        }
        XCTAssertTrue(detail.contains("example.test"))
        XCTAssertTrue(detail.contains("/watch"))
        XCTAssertTrue(detail.contains("v="))
        XCTAssertTrue(detail.contains("list="))
        XCTAssertTrue(detail.contains("proxy.test"))
        XCTAssertTrue(detail.contains("Safe context: HTTP 403 retry 2"))
    }

    func testDiagnosticDetailTreatsPasswordShortFlagsAsCaseSensitiveAndRedactsOutputPaths() {
        let detail = DownloadFailure.sanitizedDiagnosticDetail(
            "yt-dlp -u short-user -p short-password -2 two-factor -P /Users/example/Downloads"
        )

        XCTAssertFalse(detail.contains("short-user"))
        XCTAssertFalse(detail.contains("short-password"))
        XCTAssertFalse(detail.contains("two-factor"))
        XCTAssertFalse(detail.contains("/Users/example/Downloads"))
        XCTAssertTrue(detail.contains("-P [REDACTED]"))
    }

    func testDefaultSupportReportPayloadExcludesDownloadActivityAndSensitiveAttachments() throws {
        let jobID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let incidentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let failure = DownloadFailure(
            category: .clientValidationFailed,
            technicalDetail: """
            ERROR: HTTP 403 for https://user:password@media.example/watch?v=private-video&token=secret-token
            Title: Private Lecture
            Output path: /Users/example/Movies/Private Lecture.mp4
            Raw stderr: cookie=secret-cookie
            """,
            toolExitCode: 1
        )
        let selectedJob = DownloadJob.fixture(
            id: jobID,
            sourceURL: "https://user:password@media.example/watch?v=private-video",
            title: "Private Lecture",
            status: .failed,
            outputKind: .mp4,
            cookies: .chrome,
            outputURL: URL(fileURLWithPath: "/Users/example/Movies/Private Lecture.mp4")
        )
        let environment = SupportReportDraft.Environment(
            appVersion: "2.0.0-test",
            releaseChannel: "internal",
            macOSVersion: "14.6",
            architecture: "arm64",
            localeIdentifier: "zh-Hant"
        )

        let draft = SupportReportDraft.defaultPreview(
            category: .downloadFailure,
            subject: "Download failed",
            message: "Please review the sanitized local incident.",
            environment: environment,
            incidentID: incidentID,
            selectedJob: selectedJob,
            selectedFailure: failure,
            diagnosticLines: [
                "Downloading https://media.example/watch?v=private-video",
                "Cookie: SID=secret-cookie",
                "Wrote file /Users/example/Movies/Private Lecture.mp4",
                "Safe context: HTTP 403 retry 1"
            ]
        )

        XCTAssertEqual(draft.category, .downloadFailure)
        XCTAssertEqual(draft.subject, "Download failed")
        XCTAssertEqual(draft.message, "Please review the sanitized local incident.")
        XCTAssertEqual(draft.environment, environment)
        XCTAssertEqual(draft.incidentID, incidentID)
        XCTAssertEqual(draft.failure?.jobID, jobID)
        XCTAssertEqual(draft.failure?.category, .clientValidationFailed)
        XCTAssertEqual(draft.failure?.toolExitCode, 1)
        XCTAssertNil(draft.optionalFields.sourceURL)
        XCTAssertNil(draft.optionalFields.mediaTitle)
        XCTAssertNil(draft.optionalFields.screenshotName)
        XCTAssertNil(draft.optionalFields.mediaFileName)

        let encodedPayload = String(data: try JSONEncoder().encode(draft), encoding: .utf8)!
        for forbidden in [
            "user", "password", "private-video", "secret-token", "Private Lecture",
            "/Users/example/Movies", "secret-cookie", "chrome", "thumbnail",
            "sourceURL", "outputURL", "sourceMetadata", "screenshot", "mediaFile"
        ] {
            XCTAssertFalse(encodedPayload.contains(forbidden), "Default support payload leaked \(forbidden)")
        }
        XCTAssertTrue(encodedPayload.contains("HTTP 403"))
        XCTAssertTrue(encodedPayload.contains("[REDACTED]"))
    }
}
