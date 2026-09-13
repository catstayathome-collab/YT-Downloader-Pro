import Combine
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
        let provider = ControlledAuthenticationProvider(kind: .google)
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

    func testCancellationRestoresPriorStableStateEvenWhenProviderFinishesLater() async throws {
        let provider = ControlledAuthenticationProvider(kind: .google)
        let diagnostics = RecordingAuthenticationDiagnostics()
        var store: AccountSessionStore? = AccountSessionStore.fixture(
            provider: provider,
            diagnostics: diagnostics
        )
        weak let weakStore = store
        let operationReturned = expectation(description: "sign-in operation returned")
        let completion = AuthenticationCompletionProbe()
        let signIn = Task { [weak store] in
            await store?.signIn(with: .google)
            await completion.markComplete()
            operationReturned.fulfill()
        }
        await provider.waitUntilSignInStarts()
        XCTAssertEqual(store?.isAuthenticationCancellationAvailable, true)

        store?.cancelAuthentication()
        XCTAssertEqual(store?.state, .signedOut)
        XCTAssertEqual(store?.isAuthenticationCancellationAvailable, false)
        await fulfillment(of: [operationReturned], timeout: 1.0)
        let returnedBeforeProvider = await completion.isComplete
        let providerIsStillPending = await provider.hasPendingSignIn
        XCTAssertTrue(returnedBeforeProvider)
        XCTAssertTrue(providerIsStillPending)
        if returnedBeforeProvider {
            await signIn.value
            store = nil
            XCTAssertNil(weakStore)
        }

        await provider.finishSignIn(.success(.fixture(provider: .google)))
        await provider.waitUntilSignInFinishes()
        await signIn.value
        await diagnostics.waitForEventCount(2)

        let events = await diagnostics.events
        store = nil
        XCTAssertNil(weakStore)
        XCTAssertEqual(events, [.signInStarted, .signInCancelled])
    }

    func testSynchronousCancellationSubscriberStopsSignInBeforeProviderStarts() async {
        let session = AuthenticationSession.fixture(
            provider: .google,
            accountID: "cancelled-account",
            refreshCredential: "cancelled-refresh"
        )
        let vault = ControlledCredentialVault()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .success(session)
        )
        let store = AccountSessionStore.fixture(provider: provider, vault: vault)
        var didCancelFromTrueTransition = false
        let cancellationObserver = store.$isAuthenticationCancellationAvailable
            .dropFirst()
            .sink { isAvailable in
                guard isAvailable, !didCancelFromTrueTransition else { return }
                didCancelFromTrueTransition = true
                store.cancelAuthentication()
            }

        await store.signIn(with: .google)

        let providerOperations = await provider.counter.operations
        let vaultOperations = await vault.operations
        let storedEnvelope = await vault.storedEnvelope
        XCTAssertTrue(didCancelFromTrueTransition)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertFalse(store.isAuthenticationCancellationAvailable)
        XCTAssertEqual(providerOperations, [])
        XCTAssertEqual(vaultOperations, [])
        XCTAssertNil(storedEnvelope)
        _ = cancellationObserver
    }

    func testSynchronousCancellationSubscriberStopsRestoreBeforeVaultLoad() async {
        let originalEnvelope = StoredCredentialEnvelope.fixture(
            provider: .google,
            refreshCredential: "preserved-refresh"
        )
        let vault = ControlledCredentialVault(initial: originalEnvelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            restoreResult: .success(.fixture(provider: .google))
        )
        let store = AccountSessionStore.fixture(provider: provider, vault: vault)
        var didCancelFromTrueTransition = false
        let cancellationObserver = store.$isAuthenticationCancellationAvailable
            .dropFirst()
            .sink { isAvailable in
                guard isAvailable, !didCancelFromTrueTransition else { return }
                didCancelFromTrueTransition = true
                store.cancelAuthentication()
            }

        await store.restoreSession()

        let providerOperations = await provider.counter.operations
        let vaultOperations = await vault.operations
        let storedEnvelope = await vault.storedEnvelope
        XCTAssertTrue(didCancelFromTrueTransition)
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertFalse(store.isAuthenticationCancellationAvailable)
        XCTAssertEqual(providerOperations, [])
        XCTAssertEqual(vaultOperations, [])
        XCTAssertEqual(storedEnvelope, originalEnvelope)
        _ = cancellationObserver
    }

    func testRapidDuplicateSignInStartsOnlyOneProviderOperation() async {
        let provider = ControlledAuthenticationProvider(kind: .google)
        let store = AccountSessionStore.fixture(provider: provider)
        let first = Task { await store.signIn(with: .google) }
        await provider.waitUntilSignInStarts()

        let duplicate = Task { await store.signIn(with: .google) }
        await duplicate.value

        let signInCallCount = await provider.signInCallCount
        XCTAssertEqual(signInCallCount, 1)
        await provider.finishSignIn(.failure(.cancelled))
        await first.value
    }

    func testCancelledProviderCompletionCannotOverwriteNewerSignInEnvelope() async {
        let staleSession = AuthenticationSession.fixture(
            provider: .google,
            accountID: "stale-account",
            refreshCredential: "stale-refresh"
        )
        let freshSession = AuthenticationSession.fixture(
            provider: .apple,
            accountID: "fresh-account",
            refreshCredential: "fresh-refresh"
        )
        let vault = ControlledCredentialVault()
        let staleProvider = ControlledAuthenticationProvider(kind: .google)
        let freshProvider = ControlledAuthenticationProvider(kind: .apple)
        let store = AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([staleProvider, freshProvider])
        )
        let staleSignIn = Task { await store.signIn(with: .google) }
        await staleProvider.waitUntilSignInStarts()

        store.cancelAuthentication()
        XCTAssertEqual(store.state, .signedOut)
        let freshSignIn = Task { await store.signIn(with: .apple) }
        await freshProvider.waitUntilSignInStarts()
        await freshProvider.finishSignIn(.success(freshSession))
        await freshSignIn.value
        await staleProvider.finishSignIn(.success(staleSession))
        await staleProvider.waitUntilSignInFinishes()
        await staleSignIn.value

        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        XCTAssertEqual(store.state, .signedIn(freshSession.summary))
        XCTAssertEqual(storedEnvelope, freshSession.storedEnvelope)
        XCTAssertEqual(operations, [.save(.mock)])
    }

    func testCancellationAfterCredentialWriteCannotInterruptCommitOrStartDuplicate() async {
        let session = AuthenticationSession.fixture(
            provider: .google,
            accountID: "committed-account",
            refreshCredential: "committed-refresh"
        )
        let vault = ControlledCredentialVault(suspendNextSaveAfterWrite: true)
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .success(session)
        )
        let duplicateProvider = ImmediateAuthenticationProvider(
            kind: .apple,
            signInResult: .failure(.invalidSession)
        )
        let store = AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([provider, duplicateProvider])
        )
        let signIn = Task { await store.signIn(with: .google) }
        await vault.waitUntilSaveWrites()
        XCTAssertFalse(store.isAuthenticationCancellationAvailable)

        store.cancelAuthentication()
        XCTAssertEqual(store.state, .signingIn(.google))
        XCTAssertFalse(store.isAuthenticationCancellationAvailable)
        await store.signIn(with: .apple)
        let duplicateOperations = await duplicateProvider.counter.operations
        XCTAssertEqual(duplicateOperations, [])

        await vault.finishSuspendedSave()
        await signIn.value

        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        XCTAssertEqual(store.state, .signedIn(session.summary))
        XCTAssertEqual(storedEnvelope, session.storedEnvelope)
        XCTAssertEqual(operations, [.save(.mock)])
    }

    func testCancellationAfterCredentialWriteCannotEnterFailingCompensationPath() async {
        let session = AuthenticationSession.fixture(
            provider: .google,
            accountID: "committed-account",
            refreshCredential: "committed-refresh"
        )
        let vault = ControlledCredentialVault(
            suspendNextSaveAfterWrite: true,
            deleteError: .unexpectedStatus(-50)
        )
        let diagnostics = RecordingAuthenticationDiagnostics()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .success(session)
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )
        let signIn = Task { await store.signIn(with: .google) }
        await vault.waitUntilSaveWrites()

        store.cancelAuthentication()
        await vault.finishSuspendedSave()
        await signIn.value
        await diagnostics.waitForEventCount(1)

        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        let events = await diagnostics.events
        XCTAssertEqual(store.state, .signedIn(session.summary))
        XCTAssertEqual(storedEnvelope, session.storedEnvelope)
        XCTAssertEqual(operations, [.save(.mock)])
        XCTAssertEqual(events, [.signInStarted])
    }

    func testSynchronousCancellationSubscriberCannotClearSignInCommitOwnership() async {
        let session = AuthenticationSession.fixture(
            provider: .google,
            accountID: "committed-account",
            refreshCredential: "committed-refresh"
        )
        let vault = ControlledCredentialVault()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .success(session)
        )
        let store = AccountSessionStore.fixture(provider: provider, vault: vault)
        var didAttemptReentrantCancellation = false
        let cancellationObserver = store.$isAuthenticationCancellationAvailable
            .dropFirst()
            .sink { isAvailable in
                guard !isAvailable, !didAttemptReentrantCancellation else { return }
                didAttemptReentrantCancellation = true
                store.cancelAuthentication()
            }
        await store.signIn(with: .google)

        XCTAssertTrue(didAttemptReentrantCancellation)
        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        XCTAssertEqual(store.state, .signedIn(session.summary))
        XCTAssertEqual(storedEnvelope, session.storedEnvelope)
        XCTAssertEqual(operations, [.save(.mock)])
        _ = cancellationObserver
    }

    func testInvalidRestoreCleanupFinishesBeforeNewSignInCanSave() async {
        let staleEnvelope = StoredCredentialEnvelope.fixture(
            provider: .google,
            refreshCredential: "stale-refresh"
        )
        let freshSession = AuthenticationSession.fixture(
            provider: .apple,
            accountID: "fresh-account",
            refreshCredential: "fresh-refresh"
        )
        let vault = ControlledCredentialVault(initial: staleEnvelope, suspendNextDelete: true)
        let staleProvider = ImmediateAuthenticationProvider(
            kind: .google,
            restoreResult: .failure(.invalidSession)
        )
        let freshProvider = ImmediateAuthenticationProvider(
            kind: .apple,
            signInResult: .success(freshSession)
        )
        let store = AccountSessionStore(
            environment: .mock,
            vault: vault,
            providers: .init([staleProvider, freshProvider])
        )
        let staleRestore = Task { await store.restoreSession() }
        await vault.waitUntilDeleteStarts()
        XCTAssertFalse(store.isAuthenticationCancellationAvailable)

        store.cancelAuthentication()
        XCTAssertEqual(store.state, .restoring)
        await vault.finishSuspendedDelete()
        await staleRestore.value
        await store.signIn(with: .apple)

        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        XCTAssertEqual(store.state, .signedIn(freshSession.summary))
        XCTAssertEqual(storedEnvelope, freshSession.storedEnvelope)
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock), .save(.mock)])
    }

    func testInvalidRestoreCleanupFailureAfterCancellationAttemptPublishesSafeFailure() async {
        let staleEnvelope = StoredCredentialEnvelope.fixture(
            provider: .google,
            refreshCredential: "stale-refresh"
        )
        let vault = ControlledCredentialVault(
            initial: staleEnvelope,
            suspendNextDelete: true,
            deleteError: .unexpectedStatus(-50)
        )
        let diagnostics = RecordingAuthenticationDiagnostics()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            restoreResult: .failure(.invalidSession)
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )
        let restoration = Task { await store.restoreSession() }
        await vault.waitUntilDeleteStarts()
        XCTAssertFalse(store.isAuthenticationCancellationAvailable)

        store.cancelAuthentication()
        XCTAssertEqual(store.state, .restoring)
        await vault.finishSuspendedDelete()
        await restoration.value

        guard store.state == .failed(.credentialRemovalFailed) else {
            XCTFail("Expected cleanup failure, got \(store.state)")
            return
        }
        await diagnostics.waitForEventCount(1)
        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        let events = await diagnostics.events
        XCTAssertEqual(storedEnvelope, staleEnvelope)
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
        XCTAssertEqual(events, [.storageUnavailable])
    }

    func testSynchronousCancellationSubscriberCannotDiscardInvalidRestoreCleanupFailure() async {
        let staleEnvelope = StoredCredentialEnvelope.fixture(
            provider: .google,
            refreshCredential: "stale-refresh"
        )
        let vault = ControlledCredentialVault(
            initial: staleEnvelope,
            deleteError: .unexpectedStatus(-50)
        )
        let diagnostics = RecordingAuthenticationDiagnostics()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            restoreResult: .failure(.invalidSession)
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )
        var didAttemptReentrantCancellation = false
        let cancellationObserver = store.$isAuthenticationCancellationAvailable
            .dropFirst()
            .sink { isAvailable in
                guard !isAvailable, !didAttemptReentrantCancellation else { return }
                didAttemptReentrantCancellation = true
                store.cancelAuthentication()
            }
        await store.restoreSession()

        XCTAssertTrue(didAttemptReentrantCancellation)
        guard store.state == .failed(.credentialRemovalFailed) else {
            XCTFail("Expected cleanup failure, got \(store.state)")
            return
        }
        await diagnostics.waitForEventCount(1)
        let storedEnvelope = await vault.storedEnvelope
        let operations = await vault.operations
        let events = await diagnostics.events
        XCTAssertEqual(storedEnvelope, staleEnvelope)
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
        XCTAssertEqual(events, [.storageUnavailable])
        _ = cancellationObserver
    }

    func testDiagnosticEventEncodingHasNoPayloadFields() throws {
        for event in AuthenticationDiagnosticEvent.allCases {
            let data = try JSONEncoder().encode(event)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(text.contains("token"))
            XCTAssertFalse(text.contains("account"))
            XCTAssertFalse(text.contains("email"))
            XCTAssertFalse(text.contains("@"))
        }
    }

    func testSuccessfulSignInRecordsOnlyStartEvent() async {
        let diagnostics = RecordingAuthenticationDiagnostics()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .success(.fixture(provider: .google))
        )
        let store = AccountSessionStore.fixture(provider: provider, diagnostics: diagnostics)

        await store.signIn(with: .google)
        await diagnostics.waitForEventCount(1)

        let events = await diagnostics.events
        XCTAssertEqual(events, [.signInStarted])
    }

    func testInvalidSignInRecordsStartedThenFailed() async {
        let diagnostics = RecordingAuthenticationDiagnostics()
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .failure(.invalidSession)
        )
        let store = AccountSessionStore.fixture(provider: provider, diagnostics: diagnostics)

        await store.signIn(with: .google)
        await diagnostics.waitForEventCount(2)

        let events = await diagnostics.events
        XCTAssertEqual(events, [.signInStarted, .signInFailed])
    }

    func testSignInStorageFailureRecordsStartedThenStorageUnavailable() async {
        let diagnostics = RecordingAuthenticationDiagnostics()
        let vault = RecordingCredentialVault(saveError: .unexpectedStatus(-50))
        let provider = ImmediateAuthenticationProvider(
            kind: .google,
            signInResult: .success(.fixture(provider: .google))
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )

        await store.signIn(with: .google)
        await diagnostics.waitForEventCount(2)

        let events = await diagnostics.events
        XCTAssertEqual(events, [.signInStarted, .storageUnavailable])
    }

    func testSuccessfulRestorationRecordsSessionRestored() async {
        let diagnostics = RecordingAuthenticationDiagnostics()
        let envelope = StoredCredentialEnvelope.fixture(
            provider: .apple,
            refreshCredential: "stored-refresh"
        )
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .success(.fixture(provider: .apple))
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )

        await store.restoreSession()
        await diagnostics.waitForEventCount(1)

        let events = await diagnostics.events
        XCTAssertEqual(events, [.sessionRestored])
    }

    func testExpiredRestorationRecordsSessionExpired() async {
        let diagnostics = RecordingAuthenticationDiagnostics()
        let envelope = StoredCredentialEnvelope.fixture(
            provider: .apple,
            refreshCredential: "stored-refresh"
        )
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .failure(.expiredSession)
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )

        await store.restoreSession()
        await diagnostics.waitForEventCount(1)

        let events = await diagnostics.events
        XCTAssertEqual(events, [.sessionExpired])
    }

    func testSuccessfulSignOutRecordsCompletedAfterRestoration() async {
        let diagnostics = RecordingAuthenticationDiagnostics()
        let envelope = StoredCredentialEnvelope.fixture(
            provider: .apple,
            refreshCredential: "stored-refresh"
        )
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(
            kind: .apple,
            restoreResult: .success(.fixture(provider: .apple))
        )
        let store = AccountSessionStore.fixture(
            provider: provider,
            vault: vault,
            diagnostics: diagnostics
        )

        await store.restoreSession()
        await store.signOut()
        await diagnostics.waitForEventCount(2)

        let events = await diagnostics.events
        XCTAssertEqual(events, [.sessionRestored, .signOutCompleted])
    }
}
