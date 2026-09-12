import Foundation
import XCTest
@testable import YTDownloaderPro2

@MainActor
final class AccountSessionStoreTests: XCTestCase {
    func testDisabledStoreNeverReadsVaultOrExposesAccountState() async {
        let vault = RecordingCredentialVault()
        let store = AccountSessionStore(environment: .disabled, vault: vault, providers: .init([]))

        await store.restoreSession()

        let operations = await vault.operations
        XCTAssertEqual(store.state, .disabled)
        XCTAssertEqual(operations, [])
    }

    func testSignInPersistsEnvelopeButKeepsAccessTokenOutOfVault() async throws {
        let vault = RecordingCredentialVault()
        let session = AuthenticationSession.fixture(provider: .google, accessToken: "memory-secret")
        let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.signIn(with: .google)

        let savedEnvelope = await vault.savedEnvelope
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .signedIn(session.summary))
        let saved = try XCTUnwrap(savedEnvelope)
        XCTAssertEqual(saved, session.storedEnvelope)
        XCTAssertFalse(String(data: try JSONEncoder().encode(saved), encoding: .utf8)!.contains("memory-secret"))
        XCTAssertEqual(providerOperations, [.signIn])
    }

    func testSignInRejectsWhitespaceOnlyRequiredSessionFieldsWithoutSaving() async {
        let whitespace = " \t\n\r "
        let cases: [(String, AuthenticationSession)] = [
            ("account ID", .fixture(provider: .google, accountID: whitespace)),
            ("display name", .fixture(provider: .google, displayName: whitespace)),
            ("access token", .fixture(provider: .google, accessToken: whitespace)),
            ("refresh credential", .fixture(provider: .google, refreshCredential: whitespace))
        ]

        for (field, session) in cases {
            let vault = RecordingCredentialVault()
            let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
            let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

            await store.signIn(with: .google)

            let operations = await vault.operations
            let providerOperations = await provider.counter.operations
            XCTAssertEqual(store.state, .failed(.invalidSession), "Accepted whitespace-only \(field)")
            XCTAssertEqual(operations, [], "Saved session with whitespace-only \(field)")
            XCTAssertEqual(providerOperations, [.signIn], "Unexpected provider calls for \(field)")
        }
    }

    func testSignInValidationPreservesOpaqueValuesContainingSurroundingWhitespace() async {
        let session = AuthenticationSession.fixture(
            provider: .google,
            accountID: " opaque-account ",
            displayName: " Demo User ",
            accessToken: " memory-access ",
            refreshCredential: " opaque-refresh "
        )
        let vault = RecordingCredentialVault()
        let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.signIn(with: .google)

        let savedEnvelope = await vault.savedEnvelope
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .signedIn(session.summary))
        XCTAssertEqual(savedEnvelope, session.storedEnvelope)
        XCTAssertEqual(providerOperations, [.signIn])
    }

    func testSignInSaveFailureDoesNotAdoptSessionAndMapsStorageError() async {
        let vault = RecordingCredentialVault(saveError: .unexpectedStatus(-50))
        let session = AuthenticationSession.fixture(provider: .google)
        let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.signIn(with: .google)

        let operations = await vault.operations
        let savedEnvelope = await vault.savedEnvelope
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .failed(.credentialStorageUnavailable))
        XCTAssertEqual(operations, [.save(.mock)])
        XCTAssertNil(savedEnvelope)
        XCTAssertEqual(providerOperations, [.signIn])
    }

    func testStandaloneUnavailableProviderFailsWithoutVaultAccess() async {
        let vault = RecordingCredentialVault()
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([]))

        await store.signIn(with: .google)

        let operations = await vault.operations
        XCTAssertEqual(store.state, .failed(.providerUnavailable))
        XCTAssertEqual(operations, [])
    }

    func testUnavailableProviderRequestDuringActiveSignInIsIgnored() async {
        let session = AuthenticationSession.fixture(provider: .google)
        let vault = RecordingCredentialVault()
        let provider = PendingSignInAuthenticationProvider(kind: .google)
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))
        let activeSignIn = Task { await store.signIn(with: .google) }
        await provider.waitUntilSignInStarts()

        await store.signIn(with: .apple)

        XCTAssertEqual(store.state, .signingIn(.google))
        await provider.finishSignIn(.success(session))
        await activeSignIn.value
        let operations = await vault.operations
        let signInCallCount = await provider.signInCallCount
        XCTAssertEqual(store.state, .signedIn(session.summary))
        XCTAssertEqual(operations, [.save(.mock)])
        XCTAssertEqual(signInCallCount, 1)
    }

    func testExpiredSignInFailsBeforeVaultSave() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = AuthenticationSession.fixture(provider: .google, expiresAt: now)
        let vault = RecordingCredentialVault()
        let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
        let store = AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([provider]),
            now: { now }
        )

        await store.signIn(with: .google)

        let operations = await vault.operations
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .failed(.expiredSession))
        XCTAssertEqual(operations, [])
        XCTAssertEqual(providerOperations, [.signIn])
    }

    func testExpiredRestoreRequiresProviderReauthenticationWithoutDeletingEnvelope() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let envelope = StoredCredentialEnvelope.fixture(
            provider: .apple,
            refreshCredential: "stored-refresh",
            expiresAt: now.addingTimeInterval(60)
        )
        let expiredSession = AuthenticationSession.fixture(provider: .apple, expiresAt: now)
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .success(expiredSession)
        )
        let store = AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([provider]),
            now: { now }
        )

        await store.restoreSession()

        let operations = await vault.operations
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .requiresReauthentication(.apple))
        XCTAssertEqual(operations, [.load(.mock)])
        XCTAssertEqual(providerOperations, [.restore(envelope)])
    }

    func testInvalidRestoredSessionDeletesEnvelopeAndRequiresUnscopedReauthentication() async {
        let envelope = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "stored-refresh")
        let mismatchedSession = AuthenticationSession.fixture(provider: .google)
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .success(mismatchedSession)
        )
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.restoreSession()

        let operations = await vault.operations
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .requiresReauthentication(nil))
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
        XCTAssertEqual(providerOperations, [.restore(envelope)])
    }

    func testMalformedVaultRecordDeletesEnvelopeAndRequiresUnscopedReauthentication() async {
        let vault = RecordingCredentialVault(loadError: .malformedRecord)
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([]))

        await store.restoreSession()

        let operations = await vault.operations
        XCTAssertEqual(store.state, .requiresReauthentication(nil))
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
    }

    func testInvalidRestoreCleanupFailurePublishesCredentialRemovalFailure() async {
        let envelope = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "stored-refresh")
        let mismatchedSession = AuthenticationSession.fixture(provider: .google)
        let vault = RecordingCredentialVault(initial: envelope, deleteError: .unexpectedStatus(-50))
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .success(mismatchedSession)
        )
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.restoreSession()

        let operations = await vault.operations
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .failed(.credentialRemovalFailed))
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
        XCTAssertEqual(providerOperations, [.restore(envelope)])
    }

    func testMalformedRestoreCleanupFailurePublishesCredentialRemovalFailure() async {
        let vault = RecordingCredentialVault(
            loadError: .malformedRecord,
            deleteError: .unexpectedStatus(-50)
        )
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([]))

        await store.restoreSession()

        let operations = await vault.operations
        XCTAssertEqual(store.state, .failed(.credentialRemovalFailed))
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
    }

    func testRestoreAndSignOutUseOnlyAuthenticationStorageAndRevokeProviderCredential() async throws {
        let envelope = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "restore")
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .success(.fixture(provider: .apple))
        )
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.restoreSession()
        XCTAssertEqual(store.state, .signedIn(.fixture(provider: .apple)))
        await store.signOut()

        let operations = await vault.operations
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
        XCTAssertEqual(providerOperations, [.restore(envelope), .signOut("mock-refresh")])
    }

    func testSignOutVaultDeletionFailurePublishesCredentialRemovalFailureAfterRevocation() async {
        let session = AuthenticationSession.fixture(provider: .google, refreshCredential: "revoke-refresh")
        let vault = RecordingCredentialVault(deleteError: .unexpectedStatus(-50))
        let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.signIn(with: .google)
        await store.signOut()

        let operations = await vault.operations
        let savedEnvelope = await vault.savedEnvelope
        let providerOperations = await provider.counter.operations
        XCTAssertEqual(store.state, .failed(.credentialRemovalFailed))
        XCTAssertEqual(operations, [.save(.mock), .delete(.mock)])
        XCTAssertEqual(savedEnvelope, session.storedEnvelope)
        XCTAssertEqual(providerOperations, [.signIn, .signOut("revoke-refresh")])
    }
}
