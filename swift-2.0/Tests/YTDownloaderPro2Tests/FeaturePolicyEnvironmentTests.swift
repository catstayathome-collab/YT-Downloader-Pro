import XCTest
@testable import YTDownloaderPro2

final class FeaturePolicyEnvironmentTests: XCTestCase {
    func testOnlyExactMockValuesEnableEnforcement() {
        let defaultResolution = FeaturePolicyEnvironmentResolution.resolve(from: [:])
        let freeResolution = FeaturePolicyEnvironmentResolution.resolve(
            from: ["YTDP_FEATURE_POLICY_MODE": "mock-free"]
        )
        let proResolution = FeaturePolicyEnvironmentResolution.resolve(
            from: ["YTDP_FEATURE_POLICY_MODE": "mock-pro"]
        )

        XCTAssertEqual(defaultResolution.mode, .publicCompatibility)
        XCTAssertEqual(freeResolution.mode, .mockFree)
        XCTAssertEqual(freeResolution.context.plan, .free)
        XCTAssertEqual(proResolution.mode, .mockPro)
        XCTAssertEqual(proResolution.context.plan, .pro)

        for raw in ["", " mock-free", "mock-free ", "MOCK-FREE", "free", "pro", "unexpected"] {
            let resolution = FeaturePolicyEnvironmentResolution.resolve(
                from: ["YTDP_FEATURE_POLICY_MODE": raw]
            )
            XCTAssertEqual(resolution.mode, .publicCompatibility, raw)
            XCTAssertFalse(resolution.context.isEnforced, raw)
        }
    }

    func testUnknownValueReportsOnlySanitizedFallbackMetadata() {
        let resolution = FeaturePolicyEnvironmentResolution.resolve(
            from: ["YTDP_FEATURE_POLICY_MODE": "secret-looking-value"]
        )

        XCTAssertTrue(resolution.usedUnsupportedValueFallback)
        XCTAssertEqual(
            resolution.diagnosticDetail,
            "Unsupported feature-policy mode; using public compatibility."
        )
        XCTAssertFalse(resolution.diagnosticDetail?.contains("secret-looking-value") == true)
    }

    func testMissingValueHasNoFallbackDiagnostic() {
        let resolution = FeaturePolicyEnvironmentResolution.resolve(from: [:])

        XCTAssertFalse(resolution.usedUnsupportedValueFallback)
        XCTAssertNil(resolution.diagnosticDetail)
    }

    func testAuthenticationEnvironmentCannotChangeFeaturePolicy() {
        let accountPreview = MockPlanPreview.pro
        let policy = FeaturePolicyEnvironmentResolution.resolve(from: [:]).context

        XCTAssertEqual(accountPreview, .pro)
        XCTAssertFalse(policy.isEnforced)
        XCTAssertNil(policy.plan)
    }
}
