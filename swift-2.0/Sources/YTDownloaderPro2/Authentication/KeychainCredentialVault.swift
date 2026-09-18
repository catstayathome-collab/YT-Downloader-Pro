import Foundation
import Security

enum CredentialVaultError: Error, Equatable {
    case malformedRecord
    case unexpectedStatus(OSStatus)
}

struct KeychainCredentialVault: CredentialVault {
    static let liveServicePrefix = "com.catstayathome.YTDownloaderPro.auth"

    let servicePrefix: String

    init(servicePrefix: String = Self.liveServicePrefix) {
        self.servicePrefix = servicePrefix
    }

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? {
        var query = baseQuery(environment: environment)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialVaultError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let envelope = try? JSONDecoder().decode(StoredCredentialEnvelope.self, from: data) else {
            throw CredentialVaultError.malformedRecord
        }
        return envelope
    }

    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws {
        let data = try JSONEncoder().encode(envelope)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
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
            throw CredentialVaultError.unexpectedStatus(updateStatus)
        }

        var add = baseQuery(environment: environment)
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialVaultError.unexpectedStatus(addStatus)
        }
    }

    func delete(environment: AuthEnvironment) async throws {
        let status = SecItemDelete(baseQuery(environment: environment) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.unexpectedStatus(status)
        }
    }

    private func baseQuery(environment: AuthEnvironment) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(environment.storageNamespace)",
            kSecAttrAccount as String: "active-session",
            kSecAttrSynchronizable as String: false
        ]
    }
}
