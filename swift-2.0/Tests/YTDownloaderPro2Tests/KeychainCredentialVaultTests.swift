import Foundation
import XCTest
@testable import YTDownloaderPro2

final class KeychainCredentialVaultTests: XCTestCase {
    func testRoundTripUsesDisposableServiceNamespace() async throws {
        guard ProcessInfo.processInfo.environment["YTDP_RUN_KEYCHAIN_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set YTDP_RUN_KEYCHAIN_INTEGRATION_TESTS=1 for the focused Keychain integration test")
        }
        let service = "com.catstayathome.YTDownloaderPro.tests.\(UUID().uuidString)"
        let vault = KeychainCredentialVault(servicePrefix: service)
        let envelope = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "round-trip")
        addTeardownBlock { try? await vault.delete(environment: .mock) }

        try await vault.save(envelope, environment: .mock)
        let loadedEnvelope = try await vault.load(environment: .mock)
        XCTAssertEqual(loadedEnvelope, envelope)
        try await vault.delete(environment: .mock)
        let deletedValue = try await vault.load(environment: .mock)
        XCTAssertNil(deletedValue)
    }
}
