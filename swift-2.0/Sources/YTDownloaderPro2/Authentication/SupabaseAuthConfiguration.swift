import CryptoKit
import Foundation

enum SupabaseAuthConfigurationError: Error, Equatable, Sendable {
    case invalidConfiguration
}

struct SupabaseAuthConfiguration: Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let productIdentifier = "com.tachouweng.ytdownloaderpro2"

    let projectURL: URL
    let authURL: URL
    let publishableKey: String
    let redirectURL: URL
    let entitlementURL: URL
    let entitlementIssuer: String
    let entitlementAudience: String
    let publicKeys: [String: Data]

    static func load(data: Data) throws -> SupabaseAuthConfiguration {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw SupabaseAuthConfigurationError.invalidConfiguration
        }

        guard wire.schemaVersion == supportedSchemaVersion,
              let projectURL = trustedHTTPSURL(wire.projectURL, exactPath: ""),
              let entitlementURL = trustedHTTPSURL(
                  wire.entitlementURL,
                  exactPath: "/functions/v1/entitlement"
              ),
              entitlementURL.host?.lowercased() == projectURL.host?.lowercased(),
              let redirectURL = trustedRedirectURL(wire.redirectURL),
              isPublishableKey(wire.publishableKey),
              let issuerURL = trustedHTTPSURL(wire.entitlementIssuer, exactPath: nil),
              issuerURL.absoluteString == wire.entitlementIssuer,
              wire.entitlementAudience == productIdentifier,
              !wire.publicKeys.isEmpty
        else {
            throw SupabaseAuthConfigurationError.invalidConfiguration
        }

        return SupabaseAuthConfiguration(
            projectURL: projectURL,
            authURL: projectURL.appendingPathComponent("auth/v1"),
            publishableKey: wire.publishableKey,
            redirectURL: redirectURL,
            entitlementURL: entitlementURL,
            entitlementIssuer: wire.entitlementIssuer,
            entitlementAudience: wire.entitlementAudience,
            publicKeys: try decodePublicKeys(wire.publicKeys)
        )
    }

    private struct Wire: Decodable {
        let schemaVersion: Int
        let projectURL: String
        let publishableKey: String
        let redirectURL: String
        let entitlementURL: String
        let entitlementIssuer: String
        let entitlementAudience: String
        let publicKeys: [String: String]
    }

    private static func trustedHTTPSURL(_ value: String, exactPath: String?) -> URL? {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url
        else {
            return nil
        }

        if let exactPath {
            let normalizedPath = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
            guard normalizedPath == exactPath else { return nil }
        }
        return url
    }

    private static func trustedRedirectURL(_ value: String) -> URL? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: value),
              components.scheme == productIdentifier,
              components.host == "auth",
              components.percentEncodedPath == "/callback",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }
        return components.url
    }

    private static func isPublishableKey(_ value: String) -> Bool {
        guard value.hasPrefix("sb_publishable_"),
              value.count > "sb_publishable_".count,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
                      .contains(scalar)
              })
        else {
            return false
        }
        return true
    }

    private static func decodePublicKeys(_ values: [String: String]) throws -> [String: Data] {
        var decoded: [String: Data] = [:]
        for (keyID, encodedKey) in values {
            guard isValidKeyID(keyID),
                  let data = strictBase64URLDecode(encodedKey),
                  data.count == 65,
                  data.first == 0x04,
                  (try? P256.Signing.PublicKey(x963Representation: data)) != nil
            else {
                throw SupabaseAuthConfigurationError.invalidConfiguration
            }
            decoded[keyID] = data
        }
        return decoded
    }

    private static func isValidKeyID(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
                .contains(scalar)
        }
    }

    private static func strictBase64URLDecode(_ value: String) -> Data? {
        guard !value.isEmpty,
              !value.contains("="),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains(scalar)
              }),
              value.count % 4 != 1
        else {
            return nil
        }

        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        return base64URLEncode(decoded) == value ? decoded : nil
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct AuthEnvironmentResolution: Equatable, Sendable {
    let environment: AuthEnvironment
    let configuration: SupabaseAuthConfiguration?

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuration: SupabaseAuthConfiguration?
    ) -> AuthEnvironmentResolution {
        switch environment["YTDP_AUTH_MODE"] {
        case "mock":
            return AuthEnvironmentResolution(environment: .mock, configuration: nil)
        case "staging" where configuration != nil:
            return AuthEnvironmentResolution(environment: .staging, configuration: configuration)
        default:
            return AuthEnvironmentResolution(environment: .disabled, configuration: nil)
        }
    }
}
