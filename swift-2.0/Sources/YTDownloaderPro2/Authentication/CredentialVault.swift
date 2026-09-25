import Foundation

protocol CredentialVault: Sendable {
    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope?
    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws
    func delete(environment: AuthEnvironment) async throws
}

actor InMemoryCredentialVault: CredentialVault {
    private var storage: [AuthEnvironment: StoredCredentialEnvelope] = [:]

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? {
        storage[environment]
    }

    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws {
        storage[environment] = envelope
    }

    func delete(environment: AuthEnvironment) async throws {
        storage[environment] = nil
    }
}

enum LiveCredentialVault {
    static func make(
        authEnvironment: AuthEnvironment,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any CredentialVault {
        #if YTDP_INTERNAL_TEST
        if authEnvironment == .staging,
           processEnvironment["YTDP_STAGING_EPHEMERAL_SESSION"] == "1" {
            return InMemoryCredentialVault()
        }
        #endif
        return KeychainCredentialVault()
    }
}
