import Foundation

enum EntitlementPlan: String, Codable, Equatable, Sendable {
    case free
    case pro
}

enum EntitlementSubscriptionState: String, Codable, Equatable, Sendable {
    case none
    case active
}

enum VideoHeightPolicy: Codable, Equatable, Sendable {
    case limited(Int)
    case unlimited
}

struct EntitlementSnapshot: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let plan: EntitlementPlan
    let features: Set<FeatureID>
    let videoHeightPolicy: VideoHeightPolicy
    let subscriptionState: EntitlementSubscriptionState

    static let syntheticFree = EntitlementSnapshot(
        schemaVersion: supportedSchemaVersion,
        plan: .free,
        features: [
            .downloadSingle, .videoStandard, .audioMP3, .subtitleBasic,
            .recoveryManual, .historyLocal, .supportStandard
        ],
        videoHeightPolicy: .limited(720),
        subscriptionState: .none
    )

    static let syntheticPro = EntitlementSnapshot(
        schemaVersion: supportedSchemaVersion,
        plan: .pro,
        features: FeatureID.known,
        videoHeightPolicy: .unlimited,
        subscriptionState: .active
    )

    var isCanonicalGrant: Bool {
        switch plan {
        case .free:
            self == .syntheticFree
        case .pro:
            self == .syntheticPro
        }
    }
}
