import XCTest
@testable import YTDownloaderPro2

final class LiveCredentialVaultTests: XCTestCase {
    func testEphemeralStagingVaultIsProcessLocalInInternalBuild() async throws {
        let environment = ["YTDP_STAGING_EPHEMERAL_SESSION": "1"]
        let vault = LiveCredentialVault.make(
            authEnvironment: .staging,
            processEnvironment: environment
        )

        #if YTDP_INTERNAL_TEST
        XCTAssertTrue(vault is InMemoryCredentialVault)
        let envelope = StoredCredentialEnvelope.fixture(
            provider: .google,
            refreshCredential: "transient-test-credential"
        )
        try await vault.save(envelope, environment: .staging)
        let saved = try await vault.load(environment: .staging)
        XCTAssertEqual(saved, envelope)

        let nextLaunchVault = LiveCredentialVault.make(
            authEnvironment: .staging,
            processEnvironment: environment
        )
        let restored = try await nextLaunchVault.load(environment: .staging)
        XCTAssertNil(restored)
        #else
        XCTAssertTrue(vault is KeychainCredentialVault)
        #endif
    }

    func testEphemeralFlagDoesNotChangeOtherModesOrDefaultStagingStorage() {
        let enabled = ["YTDP_STAGING_EPHEMERAL_SESSION": "1"]
        XCTAssertTrue(
            LiveCredentialVault.make(
                authEnvironment: .staging,
                processEnvironment: [:]
            ) is KeychainCredentialVault
        )
        XCTAssertTrue(
            LiveCredentialVault.make(
                authEnvironment: .mock,
                processEnvironment: enabled
            ) is KeychainCredentialVault
        )
        XCTAssertTrue(
            LiveCredentialVault.make(
                authEnvironment: .disabled,
                processEnvironment: enabled
            ) is KeychainCredentialVault
        )
    }
}
