import Auth
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

enum SupabaseAuthServiceError: Error, Equatable, Sendable {
    case cancelled
    case invalidSession
    case expiredSession
    case unavailable
}

protocol SupabaseAuthServicing: Sendable {
    func signInWithGoogle(redirectURL: URL, scopes: String) async throws -> SupabaseSessionValue
    func refreshSession(refreshToken: String) async throws -> SupabaseSessionValue
    func signOut(refreshToken: String?) async throws
}

struct SupabaseGoogleAuthenticationProvider: AuthenticationProvider {
    static let scopes = "openid email profile"

    let kind: AuthenticationProviderKind = .google
    private let redirectURL: URL
    private let service: any SupabaseAuthServicing

    init(redirectURL: URL, service: any SupabaseAuthServicing) {
        self.redirectURL = redirectURL
        self.service = service
    }

    init(configuration: SupabaseAuthConfiguration) {
        self.init(
            redirectURL: configuration.redirectURL,
            service: SupabaseAuthClientService(configuration: configuration)
        )
    }

    func signIn() async throws -> AuthenticationSession {
        do {
            return try SupabaseSessionMapper.map(
                await service.signInWithGoogle(
                    redirectURL: redirectURL,
                    scopes: Self.scopes
                )
            )
        } catch {
            throw boundedProviderError(error)
        }
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        guard envelope.summary.provider == .google,
              hasContent(envelope.summary.accountID),
              hasContent(envelope.refreshCredential) else {
            throw AuthenticationProviderError.invalidSession
        }
        do {
            let session = try SupabaseSessionMapper.map(
                await service.refreshSession(refreshToken: envelope.refreshCredential)
            )
            guard session.summary.accountID == envelope.summary.accountID else {
                throw AuthenticationProviderError.invalidSession
            }
            return session
        } catch {
            throw boundedProviderError(error)
        }
    }

    func signOut(refreshCredential: String?) async {
        try? await service.signOut(refreshToken: refreshCredential)
    }

    private func boundedProviderError(_ error: Error) -> AuthenticationProviderError {
        switch error {
        case is CancellationError, SupabaseAuthServiceError.cancelled:
            .cancelled
        case SupabaseAuthServiceError.expiredSession:
            .expiredSession
        case SupabaseAuthServiceError.unavailable:
            .temporarilyUnavailable
        case AuthenticationProviderError.expiredSession:
            .expiredSession
        case AuthenticationProviderError.temporarilyUnavailable:
            .temporarilyUnavailable
        default:
            .invalidSession
        }
    }

    private func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct SupabaseAuthClientService: SupabaseAuthServicing {
    private let client: AuthClient

    init(configuration: SupabaseAuthConfiguration) {
        client = AuthClient(
            configuration: .init(
                url: configuration.authURL,
                headers: [
                    "apikey": configuration.publishableKey,
                    "Authorization": "Bearer \(configuration.publishableKey)"
                ],
                flowType: .pkce,
                redirectToURL: configuration.redirectURL,
                localStorage: EphemeralSupabaseAuthStorage(),
                autoRefreshToken: false
            )
        )
    }

    func signInWithGoogle(redirectURL: URL, scopes: String) async throws -> SupabaseSessionValue {
        do {
            #if canImport(AuthenticationServices)
            let session = try await client.signInWithOAuth(
                provider: .google,
                redirectTo: redirectURL,
                scopes: scopes
            )
            #else
            throw SupabaseAuthServiceError.unavailable
            #endif
            return map(session)
        } catch {
            throw map(error)
        }
    }

    func refreshSession(refreshToken: String) async throws -> SupabaseSessionValue {
        do {
            return map(try await client.refreshSession(refreshToken: refreshToken))
        } catch {
            throw map(error)
        }
    }

    func signOut(refreshToken: String?) async throws {
        do {
            if let refreshToken, !refreshToken.isEmpty {
                _ = try await client.refreshSession(refreshToken: refreshToken)
            }
            try await client.signOut(scope: .local)
        } catch {
            throw map(error)
        }
    }

    private func map(_ session: Session) -> SupabaseSessionValue {
        SupabaseSessionValue(
            userID: session.user.id,
            email: session.user.email,
            displayName: displayName(from: session.user),
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt
        )
    }

    private func displayName(from user: User) -> String? {
        for key in ["full_name", "name", "preferred_username"] {
            if let value = user.userMetadata[key]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func map(_ error: Error) -> SupabaseAuthServiceError {
        if error is CancellationError {
            return .cancelled
        }
        #if canImport(AuthenticationServices)
        if let webError = error as? ASWebAuthenticationSessionError,
           webError.code == .canceledLogin {
            return .cancelled
        }
        #endif
        if error is URLError {
            return .unavailable
        }
        if let authError = error as? AuthError {
            switch authError {
            case .sessionMissing:
                return .expiredSession
            case let .api(_, errorCode, _, response):
                if [
                    .sessionNotFound,
                    .sessionExpired,
                    .refreshTokenNotFound,
                    .refreshTokenAlreadyUsed,
                    .invalidJWT
                ].contains(errorCode) {
                    return .expiredSession
                }
                if response.statusCode == 408 || response.statusCode == 429 || response.statusCode >= 500 {
                    return .unavailable
                }
                if [
                    .requestTimeout,
                    .overRequestRateLimit
                ].contains(errorCode) {
                    return .unavailable
                }
            default:
                break
            }
        }
        return .invalidSession
    }
}
