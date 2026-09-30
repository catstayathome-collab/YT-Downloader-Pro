import Foundation
import XCTest
@testable import YTDownloaderPro2

final class AppSettingsTests: XCTestCase {
    func testMP4ModePersistsInDefaultsAndJobEditsRemainIndependent() throws {
        let suite = "settings-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults, key: "test-settings")
        var settings = AppSettings.defaults
        settings.defaultOptions.mp4OutputMode = .originalEncoding
        store.save(settings)
        XCTAssertEqual(store.load().defaultOptions.mp4OutputMode, .originalEncoding)
        var job = DownloadJob.fixture(status: .queued)
        job.options = store.load().defaultOptions
        job.options.mp4OutputMode = .quickTimeCompatible
        let restored = try JSONDecoder().decode(DownloadJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.options.mp4OutputMode, .quickTimeCompatible)
        XCTAssertEqual(store.load().defaultOptions.mp4OutputMode, .originalEncoding)
    }

    func testResetRemovesOnlyOwnedPreferenceAndIsIdempotent() throws {
        let suite = "settings-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults, key: "test-settings")
        var settings = AppSettings.defaults
        settings.defaultOptions.outputDirectoryBookmark = Data("private-bookmark".utf8)
        settings.maximumConcurrentDownloads = 9
        store.save(settings)
        defaults.set("keep", forKey: "unrelated")

        store.reset()
        store.reset()

        XCTAssertNil(defaults.object(forKey: "test-settings"))
        XCTAssertEqual(store.load(), .defaults)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }
}
