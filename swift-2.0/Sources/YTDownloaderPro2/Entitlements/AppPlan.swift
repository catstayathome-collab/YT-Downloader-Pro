import Foundation

enum AppBuildChannel: String, Equatable, Sendable {
    case publicRelease = "public"
    case internalTest = "internal-test"

    static var current: Self {
#if YTDP_INTERNAL_TEST
        .internalTest
#else
        .publicRelease
#endif
    }
}

enum AppPlan: String, Codable, Equatable, Sendable {
    case free
    case pro
    case testPro = "test-pro"

    var featurePolicyContext: FeaturePolicyContext {
        let snapshot: EntitlementSnapshot = self == .free ? .syntheticFree : .syntheticPro
        return .enforced(FeaturePolicy(snapshot: snapshot))
    }
}
