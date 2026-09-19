import SwiftUI
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class LocalizedSheetRootTests: XCTestCase {
    func testModalRootKeepsTheExplicitAppLocaleInsteadOfFallingBackToTheSystemLocale() {
        let root = LocalizedSheetRoot(locale: Locale(identifier: "zh-Hant")) {
            EmptyView()
        }

        XCTAssertEqual(root.locale.identifier, "zh-Hant")
    }
}
