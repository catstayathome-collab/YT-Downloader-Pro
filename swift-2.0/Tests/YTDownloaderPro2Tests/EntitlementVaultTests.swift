import Foundation
import XCTest
@testable import YTDownloaderPro2

final class EntitlementVaultTests: XCTestCase {
    func testInMemoryVaultStoresOneIndependentTokenPerEnvironment() async throws {
        let vault = InMemoryEntitlementVault()

        try await vault.save("mock-token", environment: .mock)
        try await vault.save("staging-token", environment: .staging)
        try await vault.save("replacement", environment: .mock)

        let mock = try await vault.load(environment: .mock)
        let staging = try await vault.load(environment: .staging)
        let disabled = try await vault.load(environment: .disabled)
        XCTAssertEqual(mock, "replacement")
        XCTAssertEqual(staging, "staging-token")
        XCTAssertNil(disabled)
    }

    func testDeleteIsIdempotentAndEnvironmentScoped() async throws {
        let vault = InMemoryEntitlementVault()
        try await vault.save("mock-token", environment: .mock)
        try await vault.save("staging-token", environment: .staging)

        try await vault.delete(environment: .mock)
        try await vault.delete(environment: .mock)

        let mock = try await vault.load(environment: .mock)
        let staging = try await vault.load(environment: .staging)
        XCTAssertNil(mock)
        XCTAssertEqual(staging, "staging-token")
    }

    func testMalformedVaultRecordRemainsTypedFailure() async {
        let store = VerifiedEntitlementStore(vault: MalformedEntitlementVault())

        do {
            _ = try await store.compactToken(environment: .staging)
            XCTFail("Expected malformed record")
        } catch {
            XCTAssertEqual(error as? EntitlementVaultError, .malformedRecord)
        }
    }

    func testLowerRevisionCannotReplaceVerifiedTokenForSameSubject() async throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let context = signer.context(subject: "account-a", now: now)
        let revisionSeven = try verifiedEntitlement(revision: 7, signer: signer, context: context, now: now)
        let revisionSix = try verifiedEntitlement(revision: 6, signer: signer, context: context, now: now)
        let store = VerifiedEntitlementStore(vault: InMemoryEntitlementVault())

        try await store.adopt(revisionSeven, environment: .staging)
        try await store.adopt(revisionSix, environment: .staging)

        let stored = try await store.load(environment: .staging)
        let compactToken = try await store.compactToken(environment: .staging)
        XCTAssertEqual(stored?.grantRevision, 7)
        XCTAssertEqual(compactToken, revisionSeven.compactToken)
    }

    func testVerifiedStoreCanReplaceRevisionForDifferentSubjectAndClearBothLayers() async throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let firstContext = signer.context(subject: "account-a", now: now)
        let secondContext = signer.context(subject: "account-b", now: now)
        let first = try verifiedEntitlement(revision: 7, signer: signer, context: firstContext, now: now)
        let second = try verifiedEntitlement(revision: 1, signer: signer, context: secondContext, now: now)
        let store = VerifiedEntitlementStore(vault: InMemoryEntitlementVault())

        try await store.adopt(first, environment: .staging)
        try await store.adopt(second, environment: .staging)
        let replacement = try await store.load(environment: .staging)
        XCTAssertEqual(replacement?.subject, "account-b")

        try await store.delete(environment: .staging)
        let deleted = try await store.load(environment: .staging)
        let deletedToken = try await store.compactToken(environment: .staging)
        XCTAssertNil(deleted)
        XCTAssertNil(deletedToken)
    }

    func testEntitlementAndAuthenticationKeychainNamespacesAreIsolated() {
        XCTAssertNotEqual(KeychainEntitlementVault.liveServicePrefix, KeychainCredentialVault.liveServicePrefix)
        XCTAssertEqual(KeychainEntitlementVault.liveServicePrefix, "com.catstayathome.YTDownloaderPro.entitlement")
    }

    private func verifiedEntitlement(
        revision: Int,
        signer: EntitlementTestSigner,
        context: EntitlementVerificationContext,
        now: Date
    ) throws -> VerifiedEntitlement {
        var claims = signer.validClaims(subject: context.subject, now: now)
        claims["grantRevision"] = revision
        return try EntitlementVerifier().verify(token: try signer.sign(claims: claims), context: context)
    }
}

private struct MalformedEntitlementVault: EntitlementVault {
    func load(environment: AuthEnvironment) async throws -> String? {
        throw EntitlementVaultError.malformedRecord
    }

    func save(_ verifiedCompactToken: String, environment: AuthEnvironment) async throws {}
    func delete(environment: AuthEnvironment) async throws {}
}
