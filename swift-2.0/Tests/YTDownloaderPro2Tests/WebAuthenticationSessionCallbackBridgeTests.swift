#if canImport(AuthenticationServices)
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class WebAuthenticationSessionCallbackBridgeTests: XCTestCase {
    func testCallbackFromBackgroundQueueDeliversSuccessOnMainActor() async throws {
        let expectedURL = URL(string: "com.tachouweng.ytdownloaderpro2://auth/callback?code=test-code")!
        let delivered = expectation(description: "OAuth callback delivered")
        let received = LockedValue<URL?>(nil)

        let callback = await MainActor.run {
            WebAuthenticationSessionCallbackBridge.make { result in
                MainActor.assertIsolated()
                if case let .success(url) = result {
                    received.withLock { $0 = url }
                }
                delivered.fulfill()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            callback(expectedURL, nil)
        }

        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(received.withLock { $0 }, expectedURL)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}
#endif
