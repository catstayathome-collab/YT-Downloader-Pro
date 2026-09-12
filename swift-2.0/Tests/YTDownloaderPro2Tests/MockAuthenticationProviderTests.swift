import Foundation
import XCTest
@testable import YTDownloaderPro2

final class MockAuthenticationProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testGoogleAndAppleCreateSyntheticSessionsWithoutRealIdentityFields() async throws {
        let now = now
        for kind in AuthenticationProviderKind.allCases {
            let provider = MockAuthenticationProvider(
                kind: kind,
                now: { now },
                makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
            )

            let session = try await provider.signIn()

            XCTAssertEqual(session.summary.provider, kind)
            XCTAssertTrue(session.summary.accountID.hasPrefix("mock-"))
            XCTAssertFalse(session.summary.displayName.contains("@"))
            XCTAssertFalse(session.accessToken.isEmpty)
            XCTAssertFalse(session.refreshCredential.isEmpty)
            XCTAssertEqual(session.summary.planPreview, .pro)
        }
    }

    func testRestoreRejectsExpiredAndProviderMismatchedEnvelopes() async throws {
        let now = now
        let provider = MockAuthenticationProvider(kind: .google, now: { now })
        let expired = StoredCredentialEnvelope.fixture(
            provider: .google,
            refreshCredential: "expired",
            expiresAt: now
        )
        let wrongProvider = StoredCredentialEnvelope.fixture(
            provider: .apple,
            refreshCredential: "wrong",
            expiresAt: now.addingTimeInterval(60)
        )

        await XCTAssertThrowsAuthenticationError(.expiredSession) {
            try await provider.restore(from: expired)
        }
        await XCTAssertThrowsAuthenticationError(.invalidSession) {
            try await provider.restore(from: wrongProvider)
        }
    }

    func testRestoreRejectsWhitespaceOnlyOpaqueEnvelopeFields() async throws {
        let now = now
        let provider = MockAuthenticationProvider(kind: .google, now: { now })
        let validSummary = AccountSummary(
            provider: .google,
            accountID: "opaque-account",
            displayName: "Opaque Display Name",
            planPreview: .pro,
            expiresAt: now.addingTimeInterval(60)
        )
        let whitespaceOnly = " \t\n\r "
        let malformedEnvelopes = [
            StoredCredentialEnvelope(
                summary: AccountSummary(
                    provider: .google,
                    accountID: whitespaceOnly,
                    displayName: validSummary.displayName,
                    planPreview: validSummary.planPreview,
                    expiresAt: validSummary.expiresAt
                ),
                refreshCredential: "opaque-refresh"
            ),
            StoredCredentialEnvelope(
                summary: AccountSummary(
                    provider: .google,
                    accountID: validSummary.accountID,
                    displayName: whitespaceOnly,
                    planPreview: validSummary.planPreview,
                    expiresAt: validSummary.expiresAt
                ),
                refreshCredential: "opaque-refresh"
            ),
            StoredCredentialEnvelope(
                summary: validSummary,
                refreshCredential: whitespaceOnly
            )
        ]

        for envelope in malformedEnvelopes {
            await XCTAssertThrowsAuthenticationError(.invalidSession) {
                try await provider.restore(from: envelope)
            }
        }
    }
}

private func XCTAssertThrowsAuthenticationError<Value>(
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
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
