import Foundation
import Security

enum EntitlementVaultError: Error, Equatable, Sendable {
    case malformedRecord
    case unexpectedStatus(OSStatus)
}

protocol EntitlementVault: Sendable {
    func load(environment: AuthEnvironment) async throws -> String?
    func save(_ verifiedCompactToken: String, environment: AuthEnvironment) async throws
    func delete(environment: AuthEnvironment) async throws
}

actor InMemoryEntitlementVault: EntitlementVault {
    private var storage: [AuthEnvironment: String] = [:]

    func load(environment: AuthEnvironment) async throws -> String? {
        storage[environment]
    }

    func save(_ verifiedCompactToken: String, environment: AuthEnvironment) async throws {
        guard Self.isValidRecord(verifiedCompactToken) else {
            throw EntitlementVaultError.malformedRecord
        }
        storage[environment] = verifiedCompactToken
    }

    func delete(environment: AuthEnvironment) async throws {
        storage[environment] = nil
    }

    private static func isValidRecord(_ token: String) -> Bool {
        !token.isEmpty && token == token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct KeychainEntitlementVault: EntitlementVault {
    static let liveServicePrefix = "com.catstayathome.YTDownloaderPro.entitlement"

    let servicePrefix: String

    init(servicePrefix: String = Self.liveServicePrefix) {
        self.servicePrefix = servicePrefix
    }

    func load(environment: AuthEnvironment) async throws -> String? {
        var query = baseQuery(environment: environment)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw EntitlementVaultError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty,
              token == token.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EntitlementVaultError.malformedRecord
        }
        return token
    }

    func save(_ verifiedCompactToken: String, environment: AuthEnvironment) async throws {
        guard !verifiedCompactToken.isEmpty,
              verifiedCompactToken == verifiedCompactToken.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw EntitlementVaultError.malformedRecord
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(verifiedCompactToken.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(environment: environment) as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw EntitlementVaultError.unexpectedStatus(updateStatus)
        }

        var add = baseQuery(environment: environment)
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EntitlementVaultError.unexpectedStatus(addStatus)
        }
    }

    func delete(environment: AuthEnvironment) async throws {
        let status = SecItemDelete(baseQuery(environment: environment) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EntitlementVaultError.unexpectedStatus(status)
        }
    }

    private func baseQuery(environment: AuthEnvironment) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(environment.storageNamespace)",
            kSecAttrAccount as String: "verified-token",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

actor VerifiedEntitlementStore {
    private let vault: any EntitlementVault
    private var verifiedByEnvironment: [AuthEnvironment: VerifiedEntitlement] = [:]

    init(vault: any EntitlementVault) {
        self.vault = vault
    }

    func adopt(_ entitlement: VerifiedEntitlement, environment: AuthEnvironment) async throws {
        if let current = verifiedByEnvironment[environment],
           current.subject == entitlement.subject,
           current.grantRevision > entitlement.grantRevision {
            return
        }
        try await vault.save(entitlement.compactToken, environment: environment)
        verifiedByEnvironment[environment] = entitlement
    }

    func load(environment: AuthEnvironment) async throws -> VerifiedEntitlement? {
        verifiedByEnvironment[environment]
    }

    func compactToken(environment: AuthEnvironment) async throws -> String? {
        try await vault.load(environment: environment)
    }

    func delete(environment: AuthEnvironment) async throws {
        try await vault.delete(environment: environment)
        verifiedByEnvironment[environment] = nil
    }
}
