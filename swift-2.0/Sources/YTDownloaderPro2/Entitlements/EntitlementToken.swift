import Foundation

enum EntitlementUse: Equatable, Sendable {
    case current
    case offlineGrace
    case expired
}

struct VerifiedEntitlement: Equatable, Sendable {
    static let offlineGraceDuration: TimeInterval = 72 * 60 * 60

    let compactToken: String
    let subject: String
    let grantRevision: Int64
    let issuedAt: Date
    let expiresAt: Date
    let snapshot: EntitlementSnapshot

    func use(at date: Date, allowOfflineGrace: Bool = false) -> EntitlementUse {
        if date < expiresAt {
            return .current
        }
        guard allowOfflineGrace,
              snapshot.plan == .pro,
              snapshot.subscriptionState == .active,
              date <= expiresAt.addingTimeInterval(Self.offlineGraceDuration) else {
            return .expired
        }
        return .offlineGrace
    }
}
