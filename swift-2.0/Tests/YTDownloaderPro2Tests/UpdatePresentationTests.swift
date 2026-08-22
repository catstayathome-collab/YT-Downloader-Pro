import Foundation
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class UpdatePresentationTests: XCTestCase {
    private let locales = ["en", "ja", "zh-Hant"].map(Locale.init(identifier:))

    func testManualCheckControlHasLocalizedVisibleAndAccessibilityLabels() {
        for locale in locales {
            let title = UpdateControlPresentation.checkTitle(locale: locale)
            let accessibilityLabel = UpdateControlPresentation.accessibilityLabel(locale: locale)

            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(accessibilityLabel.isEmpty)
            XCTAssertNotEqual(title, L10n.Key.updateCheck.rawValue)
            XCTAssertNotEqual(accessibilityLabel, L10n.Key.updateCheckAccessibility.rawValue)
        }
    }

    func testEveryUserVisibleUpdateOutcomeHasLocalizedPresentation() throws {
        let manifest = MacOSUpdateManifest.presentationFixture()
        let results: [UpdateResult] = [
            .available(manifest),
            .unsupportedOS(manifest),
            .upToDate,
            .failed(.actionableNetwork),
            .failed(.invalidManifest),
            .failed(.invalidVersion)
        ]

        for locale in locales {
            for result in results {
                let notice = UpdateNotice(id: 1, result: result, origin: .manual)
                let presentation = try XCTUnwrap(UpdateAlertPresentation(notice: notice, locale: locale))

                XCTAssertFalse(presentation.title.isEmpty)
                XCTAssertFalse(presentation.message.isEmpty)
                XCTAssertFalse(presentation.dismissTitle.isEmpty)
                if case .available = result {
                    XCTAssertEqual(presentation.releaseURL, manifest.releaseURL)
                    XCTAssertTrue(presentation.message.contains(manifest.latestVersion))
                    XCTAssertFalse(try XCTUnwrap(presentation.openReleaseTitle).isEmpty)
                }
                if case .unsupportedOS = result {
                    XCTAssertTrue(presentation.message.contains(manifest.minimumMacOS))
                }
            }
        }
    }

    func testSilentTransientResultNeverCreatesUserPresentation() {
        let notice = UpdateNotice(id: 1, result: .failed(.silentTransient), origin: .automatic)

        XCTAssertNil(UpdateAlertPresentation(notice: notice, locale: Locale(identifier: "en")))
    }

    func testReleaseCommandOpensOnlyCredentialFreeHTTPSURL() throws {
        let safeURL = try XCTUnwrap(URL(string: "https://github.com/example/releases/tag/v2.0.1"))
        let unsafeURLs = [
            "http://github.com/example/releases/tag/v2.0.1",
            "https://user:secret@github.com/example/releases/tag/v2.0.1",
            "file:///tmp/release"
        ]
        var openedURL: URL?

        XCTAssertTrue(UpdateReleaseCommand.open(safeURL) { url in
            openedURL = url
            return true
        })
        XCTAssertEqual(openedURL, safeURL)

        for source in unsafeURLs {
            openedURL = nil
            let url = try XCTUnwrap(URL(string: source))
            XCTAssertFalse(UpdateReleaseCommand.open(url) { openedURL = $0; return true })
            XCTAssertNil(openedURL)
        }
    }
}

private extension MacOSUpdateManifest {
    static func presentationFixture() -> MacOSUpdateManifest {
        MacOSUpdateManifest(
            schemaVersion: 1,
            platform: "macos",
            latestVersion: "2.0.1",
            minimumMacOS: "14.0.0",
            releaseURL: URL(string: "https://github.com/example/releases/tag/v2.0.1")!,
            downloadURL: URL(string: "https://github.com/example/releases/download/v2.0.1/app.zip")!,
            sha256: String(repeating: "0", count: 64),
            publishedAt: "2026-08-18T00:00:00Z",
            releaseNotes: "Example release notes."
        )
    }
}
