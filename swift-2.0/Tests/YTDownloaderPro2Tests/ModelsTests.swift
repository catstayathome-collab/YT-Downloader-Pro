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
        XCTAssertTrue(detail.contains("v=public"))
        XCTAssertTrue(detail.contains("format=best"))
        XCTAssertTrue(detail.contains("[REDACTED]"))
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

    func testDiagnosticDetailTreatsShortFlagsAsCaseSensitive() {
        let detail = DownloadFailure.sanitizedDiagnosticDetail(
            "yt-dlp -u short-user -p short-password -2 two-factor -P /Users/example/Downloads"
        )

        XCTAssertFalse(detail.contains("short-user"))
        XCTAssertFalse(detail.contains("short-password"))
        XCTAssertFalse(detail.contains("two-factor"))
        XCTAssertTrue(detail.contains("-P /Users/example/Downloads"))
    }
}
