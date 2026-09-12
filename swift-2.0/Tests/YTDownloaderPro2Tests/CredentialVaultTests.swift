import Foundation
import XCTest
@testable import YTDownloaderPro2

final class CredentialVaultTests: XCTestCase {
    func testInMemoryVaultKeepsOneEnvelopePerEnvironment() async throws {
        let vault = InMemoryCredentialVault()
        let first = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "first")
        let replacement = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "replacement")

        try await vault.save(first, environment: .mock)
        try await vault.save(replacement, environment: .mock)

        let loadedReplacement = try await vault.load(environment: .mock)
        XCTAssertEqual(loadedReplacement, replacement)
        try await vault.delete(environment: .mock)
        let deletedValue = try await vault.load(environment: .mock)
        XCTAssertNil(deletedValue)
    }
}

extension StoredCredentialEnvelope {
    static func fixture(
        provider: AuthenticationProviderKind,
        refreshCredential: String,
        expiresAt: Date = Date(timeIntervalSince1970: 4_000)
    ) -> StoredCredentialEnvelope {
        StoredCredentialEnvelope(
            summary: AccountSummary(
                provider: provider,
                accountID: "mock-account",
                displayName: "Demo User",
                planPreview: .pro,
                expiresAt: expiresAt
            ),
            refreshCredential: refreshCredential
        )
    }
}
