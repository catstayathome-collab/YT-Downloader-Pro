import Foundation
import XCTest
@testable import YTDownloaderPro2

final class SupabaseAuthConfigurationTests: XCTestCase {
    func testBundledLoaderUsesTheSameStrictValidationAndFailsClosed() {
        let loaded = SupabaseAuthConfiguration.loadBundled(
            bundle: .module,
            resourceName: "supabase-staging-configuration"
        )
        let missing = SupabaseAuthConfiguration.loadBundled(
            bundle: .module,
            resourceName: "missing-configuration"
        )

        XCTAssertEqual(loaded?.projectURL.absoluteString, "https://staging-ref.supabase.co")
        XCTAssertNil(missing)
    }

    func testValidStagingConfigurationDerivesExactTrustedEndpoints() throws {
        let configuration = try SupabaseAuthConfiguration.load(data: fixtureData())

        XCTAssertEqual(configuration.projectURL.absoluteString, "https://staging-ref.supabase.co")
        XCTAssertEqual(configuration.authURL.absoluteString, "https://staging-ref.supabase.co/auth/v1")
        XCTAssertEqual(
            configuration.entitlementURL.absoluteString,
            "https://staging-ref.supabase.co/functions/v1/entitlement"
        )
        XCTAssertEqual(configuration.redirectURL.scheme, "com.tachouweng.ytdownloaderpro2")
        XCTAssertEqual(configuration.publicKeys.keys.sorted(), ["test-es256-2026-09"])
        XCTAssertEqual(configuration.publicKeys["test-es256-2026-09"]?.count, 65)
    }

    func testConfigurationRejectsUnsafeURLShapesAndSecretKeyPrefixes() throws {
        let cases: [(String, String)] = [
            ("projectURL", "http://staging-ref.supabase.co"),
            ("projectURL", "https://user:password@staging-ref.supabase.co"),
            ("projectURL", "https://staging-ref.supabase.co:443"),
            ("projectURL", "https://staging-ref.supabase.co/unexpected-path"),
            ("projectURL", "https://staging-ref.supabase.co?token=secret"),
            ("projectURL", "https://staging-ref.supabase.co#fragment"),
            ("projectURL", "https:///missing-host"),
            ("entitlementURL", "http://staging-ref.supabase.co/functions/v1/entitlement"),
            ("entitlementURL", "https://other.example/functions/v1/entitlement"),
            ("entitlementURL", "https://staging-ref.supabase.co/functions/v1/entitlement/extra"),
            ("entitlementURL", "https://staging-ref.supabase.co/functions/v1/entitlement?secret=value"),
            ("entitlementURL", "https://staging-ref.supabase.co:443/functions/v1/entitlement"),
            ("entitlementURL", "https://user@staging-ref.supabase.co/functions/v1/entitlement"),
            ("redirectURL", "https://staging-ref.supabase.co/auth/callback"),
            ("redirectURL", "com.tachouweng.ytdownloaderpro2://auth/callback?code=value"),
            ("redirectURL", "com.tachouweng.ytdownloaderpro2://auth/callback#fragment"),
            ("publishableKey", "sb_secret_forbidden"),
            ("publishableKey", "service_role_forbidden"),
            ("publishableKey", jwtLookingValue)
        ]

        for (field, value) in cases {
            XCTAssertThrowsError(
                try SupabaseAuthConfiguration.load(data: mutation(field, value)),
                "Expected rejection for \(field)"
            )
        }
    }

    func testConfigurationRejectsInvalidSchemaTextAndPublicKeysWithoutLeakingInput() throws {
        let secretMarker = "must-never-be-echoed"
        let cases: [(String, Any)] = [
            ("schemaVersion", 2),
            ("entitlementIssuer", ""),
            ("entitlementAudience", "   "),
            ("entitlementAudience", "com.attacker.otherapp"),
            ("publicKeys", [:]),
            ("publicKeys", ["": validPublicKey]),
            ("publicKeys", ["unsafe key": validPublicKey]),
            ("publicKeys", ["test-key": "not_base64url+"]),
            ("publicKeys", ["test-key": "AQID"]),
            ("projectURL", "https://\(secretMarker)@staging-ref.supabase.co")
        ]

        for (field, value) in cases {
            do {
                _ = try SupabaseAuthConfiguration.load(data: mutation(field, value))
                XCTFail("Expected rejection for \(field)")
            } catch {
                XCTAssertFalse(String(describing: error).contains(secretMarker))
                XCTAssertEqual(String(describing: error), "invalidConfiguration")
            }
        }
    }

    func testEnvironmentResolutionEnablesOnlyExactMockOrConfiguredStaging() throws {
        let configuration = try SupabaseAuthConfiguration.load(data: fixtureData())

        XCTAssertEqual(AuthEnvironmentResolution.resolve(environment: [:], configuration: nil).environment, .disabled)
        XCTAssertEqual(
            AuthEnvironmentResolution.resolve(environment: ["YTDP_AUTH_MODE": "mock"], configuration: nil).environment,
            .mock
        )
        XCTAssertEqual(
            AuthEnvironmentResolution.resolve(
                environment: ["YTDP_AUTH_MODE": "staging"],
                configuration: configuration
            ).environment,
            .staging
        )
        XCTAssertEqual(
            AuthEnvironmentResolution.resolve(
                environment: ["YTDP_AUTH_MODE": "STAGING"],
                configuration: configuration
            ).environment,
            .disabled
        )
        XCTAssertEqual(
            AuthEnvironmentResolution.resolve(
                environment: ["YTDP_AUTH_MODE": "staging"],
                configuration: nil
            ).environment,
            .disabled
        )
        XCTAssertEqual(
            AuthEnvironmentResolution.resolve(
                environment: ["YTDP_AUTH_MODE": "production"],
                configuration: configuration
            ).environment,
            .disabled
        )
    }

    private let validPublicKey =
        "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"
    private let jwtLookingValue =
        "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2lnbmF0dXJl"

    private func fixtureData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "supabase-staging-configuration",
            withExtension: "json"
        ) else {
            throw NSError(domain: "SupabaseAuthConfigurationTests", code: 1)
        }
        return try Data(contentsOf: url)
    }

    private func mutation(_ field: String, _ value: Any) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any]
        )
        object[field] = value
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
