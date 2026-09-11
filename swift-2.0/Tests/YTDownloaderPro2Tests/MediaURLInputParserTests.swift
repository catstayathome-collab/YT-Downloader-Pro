import XCTest
@testable import YTDownloaderPro2

final class MediaURLInputParserTests: XCTestCase {
    func testExtractsNewlineSeparatedURLsInFirstSeenOrder() {
        let result = MediaURLInputParser.parse("""
        https://youtu.be/one
        https://www.youtube.com/watch?v=two
        """)

        XCTAssertEqual(result.urls, [
            "https://youtu.be/one",
            "https://www.youtube.com/watch?v=two"
        ])
        XCTAssertEqual(result.rejectedCount, 0)
        XCTAssertEqual(result.duplicateCount, 0)
    }

    func testExtractsURLsSeparatedBySpacesAndTabs() {
        let result = MediaURLInputParser.parse(
            "https://youtu.be/one https://youtu.be/two\thttps://youtu.be/three"
        )

        XCTAssertEqual(result.urls, [
            "https://youtu.be/one",
            "https://youtu.be/two",
            "https://youtu.be/three"
        ])
    }

    func testPreservesOrderAcrossMixedTextAndSeparators() {
        let result = MediaURLInputParser.parse(
            "first https://youtu.be/one, then\nhttps://youtu.be/two\tlast https://youtu.be/three"
        )

        XCTAssertEqual(result.urls, [
            "https://youtu.be/one",
            "https://youtu.be/two",
            "https://youtu.be/three"
        ])
    }

    func testDeduplicatesNormalizedURLs() {
        let result = MediaURLInputParser.parse(
            "HTTPS://YOUTU.BE/one#first https://youtu.be/one#second https://youtu.be/one"
        )

        XCTAssertEqual(result.urls, ["https://youtu.be/one"])
        XCTAssertEqual(result.duplicateCount, 2)
    }

    func testRetainsDistinctQueryStrings() {
        let result = MediaURLInputParser.parse(
            "https://youtu.be/one?si=alpha https://youtu.be/one?si=beta"
        )

        XCTAssertEqual(result.urls, [
            "https://youtu.be/one?si=alpha",
            "https://youtu.be/one?si=beta"
        ])
        XCTAssertEqual(result.duplicateCount, 0)
    }

    func testRejectsCredentialBearingAndNonHTTPLinks() {
        let result = MediaURLInputParser.parse(
            "https://user:pass@example.com/watch ftp://example.com/video"
        )

        XCTAssertTrue(result.urls.isEmpty)
        XCTAssertEqual(result.rejectedCount, 2)
        XCTAssertEqual(result.duplicateCount, 0)
    }

    func testReturnsNoAcceptedURLsForProseWithoutLinks() {
        let result = MediaURLInputParser.parse("this is not a media link")

        XCTAssertEqual(result, MediaURLInputParseResult(urls: [], rejectedCount: 0, duplicateCount: 0))
    }
}
