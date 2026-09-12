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
        let initialMock = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "initial-mock")
        let replacementMock = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "replacement-mock")
        let disabledEnvelope = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "disabled")
        addTeardownBlock {
            try? await vault.delete(environment: .mock)
            try? await vault.delete(environment: .disabled)
        }

        try await vault.save(initialMock, environment: .mock)
        let loadedInitialMock = try await vault.load(environment: .mock)
        XCTAssertEqual(loadedInitialMock, initialMock)

        try await vault.save(replacementMock, environment: .mock)
        let loadedReplacementMock = try await vault.load(environment: .mock)
        XCTAssertEqual(loadedReplacementMock, replacementMock)

        try await vault.save(disabledEnvelope, environment: .disabled)
        let loadedDisabled = try await vault.load(environment: .disabled)
        XCTAssertEqual(loadedDisabled, disabledEnvelope)

        try await vault.delete(environment: .mock)
        let deletedMock = try await vault.load(environment: .mock)
        XCTAssertNil(deletedMock)
        let retainedDisabled = try await vault.load(environment: .disabled)
        XCTAssertEqual(retainedDisabled, disabledEnvelope)
    }
}
