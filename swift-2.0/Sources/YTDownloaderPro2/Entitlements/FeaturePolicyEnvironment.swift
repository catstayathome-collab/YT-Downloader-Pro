import Foundation

enum FeaturePolicyEnvironmentMode: String, Equatable, Sendable {
    case publicCompatibility
    case mockFree
    case mockPro
}

struct FeaturePolicyEnvironmentResolution: Equatable, Sendable {
    let mode: FeaturePolicyEnvironmentMode
    let context: FeaturePolicyContext
    let usedUnsupportedValueFallback: Bool

    var diagnosticDetail: String? {
        usedUnsupportedValueFallback
            ? "Unsupported feature-policy mode; using public compatibility."
            : nil
    }

    static func resolve(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        switch environment["YTDP_FEATURE_POLICY_MODE"] {
        case "mock-free":
            Self(
                mode: .mockFree,
                context: .enforced(FeaturePolicy(snapshot: .syntheticFree)),
                usedUnsupportedValueFallback: false
            )
        case "mock-pro":
            Self(
                mode: .mockPro,
                context: .enforced(FeaturePolicy(snapshot: .syntheticPro)),
                usedUnsupportedValueFallback: false
            )
        case nil:
            Self(
                mode: .publicCompatibility,
                context: .publicCompatibility,
                usedUnsupportedValueFallback: false
            )
        default:
            Self(
                mode: .publicCompatibility,
                context: .publicCompatibility,
                usedUnsupportedValueFallback: true
            )
        }
    }
}
