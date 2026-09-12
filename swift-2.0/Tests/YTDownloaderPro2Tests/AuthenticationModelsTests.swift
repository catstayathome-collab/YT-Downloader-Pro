import Foundation
import XCTest
@testable import YTDownloaderPro2

final class AuthenticationModelsTests: XCTestCase {
    func testEnvironmentOnlyEnablesExactMockValue() {
        XCTAssertEqual(AuthEnvironment.resolve(from: [:]), .disabled)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": ""]), .disabled)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": "mock"]), .mock)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": "MOCK"]), .disabled)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": "production"]), .disabled)
    }

    func testStoredEnvelopeCannotSerializeTheMemoryOnlyAccessToken() throws {
        let session = AuthenticationSession(
            summary: AccountSummary(
                provider: .google,
                accountID: "mock-account",
                displayName: "Demo User",
                planPreview: .pro,
                expiresAt: Date(timeIntervalSince1970: 2_000)
            ),
            accessToken: "memory-only-access",
            refreshCredential: "stored-refresh"
        )

        let data = try JSONEncoder().encode(session.storedEnvelope)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("memory-only-access"))
        XCTAssertTrue(text.contains("stored-refresh"))
    }
}
