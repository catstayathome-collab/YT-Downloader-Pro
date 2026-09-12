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
        XCTAssertEqual(store.state, .signedIn(session.summary))
        let saved = try XCTUnwrap(savedEnvelope)
        XCTAssertEqual(saved, session.storedEnvelope)
        XCTAssertFalse(String(data: try JSONEncoder().encode(saved), encoding: .utf8)!.contains("memory-secret"))
    }

    func testRestoreAndSignOutUseOnlyAuthenticationStorage() async throws {
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
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(operations, [.load(.mock), .delete(.mock)])
    }
}
