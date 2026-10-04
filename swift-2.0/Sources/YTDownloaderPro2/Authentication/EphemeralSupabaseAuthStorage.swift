import Auth
import Foundation

/// Process-local storage for Supabase Auth's transient PKCE and session state.
/// Durable refresh credentials remain exclusively in `CredentialVault`.
final class EphemeralSupabaseAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.withLock {
            values[key] = value
        }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock {
            values[key]
        }
    }

    func remove(key: String) throws {
        _ = lock.withLock {
            values.removeValue(forKey: key)
        }
    }
}
