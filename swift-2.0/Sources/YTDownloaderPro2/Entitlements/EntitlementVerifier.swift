import CryptoKit
import Foundation

struct EntitlementVerificationContext: Sendable {
    let issuer: String
    let audience: String
    let subject: String
    let now: Date
    let allowedClockSkew: TimeInterval
    let acceptedExpiryGrace: TimeInterval
    let publicKeys: [String: P256.Signing.PublicKey]

    init(
        issuer: String,
        audience: String,
        subject: String,
        now: Date,
        allowedClockSkew: TimeInterval,
        acceptedExpiryGrace: TimeInterval = 0,
        publicKeys: [String: P256.Signing.PublicKey]
    ) {
        self.issuer = issuer
        self.audience = audience
        self.subject = subject
        self.now = now
        self.allowedClockSkew = allowedClockSkew
        self.acceptedExpiryGrace = acceptedExpiryGrace
        self.publicKeys = publicKeys
    }
}

enum EntitlementVerificationError: Error, Equatable, Sendable {
    case malformedToken
    case unsupportedAlgorithm
    case unknownKey
    case invalidSignature
    case invalidClaims
}

protocol EntitlementVerifying: Sendable {
    func verify(
        token: String,
        context: EntitlementVerificationContext
    ) throws -> VerifiedEntitlement
}

struct EntitlementVerifier: EntitlementVerifying {
    func verify(
        token: String,
        context: EntitlementVerificationContext
    ) throws -> VerifiedEntitlement {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else {
            throw EntitlementVerificationError.malformedToken
        }

        let headerData = try decodeBase64URL(segments[0])
        let claimsData = try decodeBase64URL(segments[1])
        let signatureData = try decodeBase64URL(segments[2])
        try requireExactKeys(
            in: headerData,
            expected: ["alg", "kid", "typ"]
        )
        let header = try decode(Header.self, from: headerData)
        guard header.alg == "ES256", header.typ == "JWT" else {
            throw EntitlementVerificationError.unsupportedAlgorithm
        }
        guard let publicKey = context.publicKeys[header.kid] else {
            throw EntitlementVerificationError.unknownKey
        }
        guard signatureData.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              publicKey.isValidSignature(
                  signature,
                  for: Data("\(segments[0]).\(segments[1])".utf8)
              ) else {
            throw EntitlementVerificationError.invalidSignature
        }

        let baseKeys: Set<String> = [
            "iss", "aud", "sub", "iat", "nbf", "exp", "jti", "schema",
            "plan", "features", "maxVideoHeight", "subscriptionState", "grantRevision"
        ]
        let claimKeys = try keys(in: claimsData)
        guard claimKeys == baseKeys ||
                claimKeys == baseKeys.union(["paidThroughMs", "proAccessEndsAtMs"]) else {
            throw EntitlementVerificationError.malformedToken
        }
        let claims = try decode(Claims.self, from: claimsData)
        guard (claims.schema == 1 && claimKeys == baseKeys) ||
                (claims.schema == 2 && claims.plan == "free" && claimKeys == baseKeys) ||
                (claims.schema == 2 && claims.plan == "pro" && claimKeys != baseKeys) else {
            throw EntitlementVerificationError.invalidClaims
        }
        let snapshot = try validatedSnapshot(from: claims, context: context)
        return VerifiedEntitlement(
            compactToken: token,
            subject: claims.sub,
            grantRevision: claims.grantRevision,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(claims.iat)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(claims.exp)),
            snapshot: snapshot,
            proAccessEndsAt: claims.proAccessEndsAtMs.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            }
        )
    }

    private func validatedSnapshot(
        from claims: Claims,
        context: EntitlementVerificationContext
    ) throws -> EntitlementSnapshot {
        let now = context.now.timeIntervalSince1970
        let skew = context.allowedClockSkew
        let expiryGrace = context.acceptedExpiryGrace
        guard !context.issuer.isEmpty,
              !context.audience.isEmpty,
              !context.subject.isEmpty,
              now.isFinite,
              skew.isFinite,
              skew >= 0,
              expiryGrace.isFinite,
              expiryGrace >= 0,
              claims.iss == context.issuer,
              claims.aud == context.audience,
              claims.sub == context.subject,
              UUID(uuidString: claims.jti) != nil,
              TimeInterval(claims.iat) <= now + skew,
              TimeInterval(claims.nbf) <= now + skew,
              TimeInterval(claims.exp) >= now - skew - expiryGrace,
              claims.nbf <= claims.iat,
              claims.exp > claims.iat,
              (claims.schema == 1 || claims.schema == 2),
              Set(claims.features).count == claims.features.count else {
            throw EntitlementVerificationError.invalidClaims
        }

        guard let plan = EntitlementPlan(rawValue: claims.plan),
              let state = EntitlementSubscriptionState(rawValue: claims.subscriptionState) else {
            throw EntitlementVerificationError.invalidClaims
        }
        let knownFeatures = Set(claims.features.map(FeatureID.init(rawValue:))).intersection(FeatureID.known)
        let heightPolicy: VideoHeightPolicy = if let height = claims.maxVideoHeight {
            .limited(height)
        } else {
            .unlimited
        }
        let snapshot = EntitlementSnapshot(
            schemaVersion: claims.schema,
            plan: plan,
            features: knownFeatures,
            videoHeightPolicy: heightPolicy,
            subscriptionState: state
        )
        guard snapshot.isCanonicalGrant else {
            throw EntitlementVerificationError.invalidClaims
        }
        if claims.schema == 2 && plan == .pro {
            guard let paidThroughMs = claims.paidThroughMs,
                  let proAccessEndsAtMs = claims.proAccessEndsAtMs,
                  paidThroughMs > 0,
                  TimeInterval(proAccessEndsAtMs) > TimeInterval(claims.iat) * 1_000,
                  (proAccessEndsAtMs == paidThroughMs ||
                      proAccessEndsAtMs - paidThroughMs == 72 * 60 * 60 * 1_000),
                  claims.exp <= proAccessEndsAtMs / 1_000 +
                      (proAccessEndsAtMs % 1_000 == 0 ? 0 : 1),
                  TimeInterval(claims.exp) - TimeInterval(claims.iat) <= 86_400 else {
                throw EntitlementVerificationError.invalidClaims
            }
        }
        switch plan {
        case .free where claims.grantRevision >= 0:
            break
        case .pro where claims.grantRevision > 0:
            break
        default:
            throw EntitlementVerificationError.invalidClaims
        }
        return snapshot
    }

    private func decodeBase64URL(_ value: String) throws -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !value.contains("="),
              value.unicodeScalars.allSatisfy(allowed.contains),
              value.count % 4 != 1 else {
            throw EntitlementVerificationError.malformedToken
        }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), encodeBase64URL(data) == value else {
            throw EntitlementVerificationError.malformedToken
        }
        return data
    }

    private func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func requireExactKeys(in data: Data, expected: Set<String>) throws {
        guard try keys(in: data) == expected else {
            throw EntitlementVerificationError.malformedToken
        }
    }

    private func keys(in data: Data) throws -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw EntitlementVerificationError.malformedToken
        }
        return Set(dictionary.keys)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EntitlementVerificationError.malformedToken
        }
    }
}

private struct Header: Decodable {
    let alg: String
    let kid: String
    let typ: String
}

private struct Claims: Decodable {
    let iss: String
    let aud: String
    let sub: String
    let iat: Int64
    let nbf: Int64
    let exp: Int64
    let jti: String
    let schema: Int
    let plan: String
    let features: [String]
    let maxVideoHeight: Int?
    let subscriptionState: String
    let grantRevision: Int64
    let paidThroughMs: Int64?
    let proAccessEndsAtMs: Int64?
}
