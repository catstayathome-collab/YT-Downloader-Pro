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

    func testSubscriptionFreeReplacesLegacyProEvenWithLowerRevision() async throws {
        let signer = EntitlementTestSigner()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let context = signer.context(subject: "account-a", now: now)
        let legacyPro = try verifiedEntitlement(revision: 7, signer: signer, context: context, now: now)
        var freeClaims = signer.validClaims(subject: "account-a", now: now)
        freeClaims["schema"] = 2
        freeClaims["plan"] = "free"
        freeClaims["features"] = EntitlementSnapshot.syntheticFree.features.map(\.rawValue).sorted()
        freeClaims["maxVideoHeight"] = 720
        freeClaims["subscriptionState"] = "none"
        freeClaims["grantRevision"] = 1
        let subscriptionFree = try EntitlementVerifier().verify(
            token: try signer.sign(claims: freeClaims), context: context
        )
        let store = VerifiedEntitlementStore(vault: InMemoryEntitlementVault())

        try await store.adopt(legacyPro, environment: .staging)
        try await store.adopt(subscriptionFree, environment: .staging)
        let stored = try await store.load(environment: .staging)
        XCTAssertEqual(stored?.snapshot.plan, .free)
        try await store.adopt(legacyPro, environment: .staging)
        let token = try await store.compactToken(environment: .staging)
        XCTAssertEqual(token, subscriptionFree.compactToken)
    }

    func testNewSubscriptionOrderCanReplaceOlderFreeDespiteRevisionReset() async throws {
        let signer = EntitlementTestSigner()
        let context = signer.context(subject: "account-a", now: Date(timeIntervalSince1970: 2_000_020))
        var oldFree = signer.validClaims(subject: "account-a", now: Date(timeIntervalSince1970: 2_000_000))
        oldFree["schema"] = 2
        oldFree["plan"] = "free"
        oldFree["features"] = EntitlementSnapshot.syntheticFree.features.map(\.rawValue).sorted()
        oldFree["maxVideoHeight"] = 720
        oldFree["subscriptionState"] = "none"
        oldFree["grantRevision"] = 9
        var newPro = signer.validClaims(subject: "account-a", now: Date(timeIntervalSince1970: 2_000_010))
        newPro["schema"] = 2
        newPro["grantRevision"] = 1
        newPro["exp"] = 2_000_110
        newPro["paidThroughMs"] = 2_000_200_000
        newPro["proAccessEndsAtMs"] = 2_000_200_000
        let free = try EntitlementVerifier().verify(token: try signer.sign(claims: oldFree), context: context)
        let pro = try EntitlementVerifier().verify(token: try signer.sign(claims: newPro), context: context)
        let store = VerifiedEntitlementStore(vault: InMemoryEntitlementVault())

        try await store.adopt(free, environment: .staging)
        try await store.adopt(pro, environment: .staging)
        let active = try await store.load(environment: .staging)
        XCTAssertEqual(active?.snapshot.plan, .pro)
        try await store.adopt(free, environment: .staging)
        let afterReplay = try await store.load(environment: .staging)
        XCTAssertEqual(afterReplay?.compactToken, pro.compactToken)
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
