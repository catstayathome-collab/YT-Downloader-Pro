import Foundation
import XCTest
@testable import YTDownloaderPro2

final class SupabaseGoogleAuthenticationProviderTests: XCTestCase {
    private let redirectURL = URL(string: "com.tachouweng.ytdownloaderpro2://auth/callback")!
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func testMapperUsesImmutableUserUUIDAndMasksEmail() throws {
        let session = try SupabaseSessionMapper.map(
            SupabaseSessionValue(
                userID: userID,
                email: "person@example.com",
                displayName: "Person Example",
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: 1_790_208_000
            )
        )

        XCTAssertEqual(session.summary.accountID, userID.uuidString.lowercased())
        XCTAssertEqual(session.summary.maskedEmail, "p•••••@example.com")
        XCTAssertEqual(session.summary.displayName, "Person Example")
        XCTAssertEqual(session.summary.provider, .google)
        XCTAssertEqual(session.accessToken, "access")
        XCTAssertEqual(session.refreshCredential, "refresh")
    }

    func testDisplayEmailCannotMergeAccountsOrChangeAccountIdentity() throws {
        func mappedAccountID(userID: UUID, email: String?) throws -> String {
            try SupabaseSessionMapper.map(
                SupabaseSessionValue(
                    userID: userID,
                    email: email,
                    displayName: nil,
                    accessToken: "access",
                    refreshToken: "refresh",
                    expiresAt: 1_790_208_000
                )
            ).summary.accountID
        }

        let secondUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        XCTAssertEqual(
            try mappedAccountID(userID: userID, email: "old@example.com"),
            try mappedAccountID(userID: userID, email: "new@example.com")
        )
        XCTAssertNotEqual(
            try mappedAccountID(userID: userID, email: "shared@example.com"),
            try mappedAccountID(userID: secondUserID, email: "shared@example.com")
        )
    }

    func testMapperRejectsOversizedOrControlBearingProfileFields() throws {
        let oversizedName = String(repeating: "N", count: 121)
        let oversizedEmail = String(repeating: "e", count: 309) + "@example.com"
        let oversized = try SupabaseSessionMapper.map(
            SupabaseSessionValue(
                userID: userID,
                email: oversizedEmail,
                displayName: oversizedName,
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: 1_790_208_000
            )
        )
        let controlBearing = try SupabaseSessionMapper.map(
            SupabaseSessionValue(
                userID: userID,
                email: nil,
                displayName: "Unsafe\nName",
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: 1_790_208_000
            )
        )

        XCTAssertEqual(oversized.summary.displayName, "Google User")
        XCTAssertNil(oversized.summary.maskedEmail)
        XCTAssertEqual(controlBearing.summary.displayName, "Google User")
    }

    func testSignInRequestsOnlyGoogleWithExactRedirectAndScopes() async throws {
        let service = RecordingSupabaseAuthService(
            signInResult: .success(sessionValue(userID: userID))
        )
        let provider = SupabaseGoogleAuthenticationProvider(
            redirectURL: redirectURL,
            service: service
        )

        let session = try await provider.signIn()

        XCTAssertEqual(session.summary.accountID, userID.uuidString.lowercased())
        let calls = await service.calls
        XCTAssertEqual(calls, [.signIn(redirectURL: redirectURL, scopes: "openid email profile")])
    }

    func testCancellationMapsToBoundedProviderError() async {
        let service = RecordingSupabaseAuthService(signInResult: .failure(.cancelled))
        let provider = SupabaseGoogleAuthenticationProvider(
            redirectURL: redirectURL,
            service: service
        )

        await assertSupabaseProviderThrows(.cancelled) {
            try await provider.signIn()
        }
    }

    func testRefreshUsesStoredCredentialAndAdoptsRotatedReplacement() async throws {
        let refreshed = sessionValue(
            userID: userID,
            accessToken: "rotated-access",
            refreshToken: "rotated-refresh"
        )
        let service = RecordingSupabaseAuthService(refreshResult: .success(refreshed))
        let provider = SupabaseGoogleAuthenticationProvider(
            redirectURL: redirectURL,
            service: service
        )
        let envelope = StoredCredentialEnvelope(
            summary: try SupabaseSessionMapper.map(sessionValue(userID: userID)).summary,
            refreshCredential: "stored-refresh"
        )

        let session = try await provider.restore(from: envelope)

        XCTAssertEqual(session.accessToken, "rotated-access")
        XCTAssertEqual(session.refreshCredential, "rotated-refresh")
        let calls = await service.calls
        XCTAssertEqual(calls, [.refresh(refreshToken: "stored-refresh")])
    }

    func testRefreshRejectsMismatchedUserUUID() async throws {
        let otherUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let service = RecordingSupabaseAuthService(
            refreshResult: .success(sessionValue(userID: otherUserID))
        )
        let provider = SupabaseGoogleAuthenticationProvider(
            redirectURL: redirectURL,
            service: service
        )
        let envelope = StoredCredentialEnvelope(
            summary: try SupabaseSessionMapper.map(sessionValue(userID: userID)).summary,
            refreshCredential: "stored-refresh"
        )

        await assertSupabaseProviderThrows(.invalidSession) {
            try await provider.restore(from: envelope)
        }
    }

    func testTransientRefreshFailureRemainsTemporarilyUnavailable() async throws {
        let service = RecordingSupabaseAuthService(refreshResult: .failure(.unavailable))
        let provider = SupabaseGoogleAuthenticationProvider(
            redirectURL: redirectURL,
            service: service
        )
        let envelope = StoredCredentialEnvelope(
            summary: try SupabaseSessionMapper.map(sessionValue(userID: userID)).summary,
            refreshCredential: "stored-refresh"
        )

        await assertSupabaseProviderThrows(.temporarilyUnavailable) {
            try await provider.restore(from: envelope)
        }
    }

    func testSignOutPassesRefreshCredentialAndSuppressesRawServiceError() async {
        let service = RecordingSupabaseAuthService(signOutError: .unavailable)
        let provider = SupabaseGoogleAuthenticationProvider(
            redirectURL: redirectURL,
            service: service
        )

        await provider.signOut(refreshCredential: "current-refresh")

        let calls = await service.calls
        XCTAssertEqual(calls, [.signOut(refreshToken: "current-refresh")])
    }

    private func sessionValue(
        userID: UUID,
        accessToken: String = "access",
        refreshToken: String = "refresh"
    ) -> SupabaseSessionValue {
        SupabaseSessionValue(
            userID: userID,
            email: "person@example.com",
            displayName: "Person Example",
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: 1_790_208_000
        )
    }
}

private func assertSupabaseProviderThrows<Value>(
    _ expected: AuthenticationProviderError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Value
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as AuthenticationProviderError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type", file: file, line: line)
    }
}

private enum SupabaseServiceCall: Equatable, Sendable {
    case signIn(redirectURL: URL, scopes: String)
    case refresh(refreshToken: String)
    case signOut(refreshToken: String?)
}

private actor RecordingSupabaseAuthService: SupabaseAuthServicing {
    private(set) var calls: [SupabaseServiceCall] = []
    private let signInResult: Result<SupabaseSessionValue, SupabaseAuthServiceError>
    private let refreshResult: Result<SupabaseSessionValue, SupabaseAuthServiceError>
    private let signOutError: SupabaseAuthServiceError?

    init(
        signInResult: Result<SupabaseSessionValue, SupabaseAuthServiceError> = .failure(.unavailable),
        refreshResult: Result<SupabaseSessionValue, SupabaseAuthServiceError> = .failure(.unavailable),
        signOutError: SupabaseAuthServiceError? = nil
    ) {
        self.signInResult = signInResult
        self.refreshResult = refreshResult
        self.signOutError = signOutError
    }

    func signInWithGoogle(redirectURL: URL, scopes: String) async throws -> SupabaseSessionValue {
        calls.append(.signIn(redirectURL: redirectURL, scopes: scopes))
        return try signInResult.get()
    }

    func refreshSession(refreshToken: String) async throws -> SupabaseSessionValue {
        calls.append(.refresh(refreshToken: refreshToken))
        return try refreshResult.get()
    }

    func signOut(refreshToken: String?) async throws {
        calls.append(.signOut(refreshToken: refreshToken))
        if let signOutError { throw signOutError }
    }
}
