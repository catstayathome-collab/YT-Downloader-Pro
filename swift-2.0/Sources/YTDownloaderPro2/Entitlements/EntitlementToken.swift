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
    let proAccessEndsAt: Date?

    init(
        compactToken: String,
        subject: String,
        grantRevision: Int64,
        issuedAt: Date,
        expiresAt: Date,
        snapshot: EntitlementSnapshot,
        proAccessEndsAt: Date? = nil
    ) {
        self.compactToken = compactToken
        self.subject = subject
        self.grantRevision = grantRevision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.snapshot = snapshot
        self.proAccessEndsAt = proAccessEndsAt
    }

    func deadline(allowOfflineGrace: Bool) -> Date {
        let tokenDeadline = allowOfflineGrace
            ? expiresAt.addingTimeInterval(Self.offlineGraceDuration)
            : expiresAt
        return proAccessEndsAt.map { min(tokenDeadline, $0) } ?? tokenDeadline
    }

    func use(at date: Date, allowOfflineGrace: Bool = false) -> EntitlementUse {
        if let proAccessEndsAt, date >= proAccessEndsAt {
            return .expired
        }
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
