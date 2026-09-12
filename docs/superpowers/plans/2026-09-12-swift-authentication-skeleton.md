# Swift Authentication Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local-only, provider-neutral authentication skeleton to the macOS Swift 2.x app, with hidden-by-default account UI, mock Google and Apple flows, device-local Keychain restoration, safe diagnostics, localization, and no real identity or paid-feature behavior.

**Architecture:** Add a dedicated `Authentication` source folder whose `AccountSessionStore` is independent of `DownloadStore`. `AppLifecycle` owns both stores and injects them into SwiftUI; `AuthEnvironment` exposes mock UI only for the exact `YTDP_AUTH_MODE=mock` value. Mock providers implement the same async protocol reserved for future reviewed providers, while a vault protocol isolates Keychain and keeps normal tests in memory.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, Foundation, Security.framework, OSLog, XCTest, macOS 13+

**Spec:** `docs/superpowers/specs/2026-09-12-swift-authentication-skeleton-design.md`

## Global Constraints

- Work only in an isolated `codex/` feature worktree based on `origin/main`; do not modify or stage the dirty root worktree.
- The normal public launch has authentication disabled and exposes no account UI.
- Only the exact environment value `YTDP_AUTH_MODE=mock` enables account UI.
- Free downloads continue without an account, and mock plan labels never change download or feature behavior.
- Do not add network requests, browser callbacks, URL schemes, OAuth credentials, provider SDKs, backend endpoints, payment behavior, analytics, or real user fixtures.
- Do not pass media URLs, titles, output paths, cookies, history, or download objects into authentication APIs.
- Short-lived access tokens remain in memory; only the opaque mock restoration envelope is stored in Keychain.
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and a test-isolated Keychain service namespace.
- Authentication diagnostics contain event categories only, never credentials, complete account IDs, email addresses, Keychain data, or raw provider errors.
- User-facing strings must exist in English, Japanese, and Traditional Chinese.
- Keep Windows Python 1.8.x, billing, entitlements, paid feature gates, and cloud history out of this plan.
- Follow red-green TDD for every behavior task and use small, reviewable commits.

## File Structure

Create these focused production files:

- `swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationModels.swift`: environment, provider, session, credential, state, and presentation-error domain values.
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/CredentialVault.swift`: vault protocol and in-memory implementation.
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/KeychainCredentialVault.swift`: Security.framework persistence for one active envelope per environment.
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationProvider.swift`: provider protocol and registry lookup.
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/MockAuthenticationProvider.swift`: synthetic Google and Apple provider behavior with no I/O.
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationDiagnostics.swift`: finite, payload-free authentication diagnostic events and OSLog recorder.
- `swift-2.0/Sources/YTDownloaderPro2/Authentication/AccountSessionStore.swift`: serialized authentication state machine and in-memory access token ownership.
- `swift-2.0/Sources/YTDownloaderPro2/Views/AccountPresentation.swift`: pure sidebar/settings presentation contracts.
- `swift-2.0/Sources/YTDownloaderPro2/Views/AccountSidebarView.swift`: compact sidebar account status and Settings entry.
- `swift-2.0/Sources/YTDownloaderPro2/Views/AccountSettingsSection.swift`: mock account management section.
- `docs/swift-2.0/AUTHENTICATION.md`: maintenance and extension guide.

Create these focused test files:

- `swift-2.0/Tests/YTDownloaderPro2Tests/AuthenticationModelsTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/CredentialVaultTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/KeychainCredentialVaultTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/MockAuthenticationProviderTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/AccountPresentationTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift`

Modify only these existing files:

- `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`: own, restore, and inject the account store.
- `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift`: reserve the sidebar-bottom account entry.
- `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift`: place account management first when enabled.
- `swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift`: add explicit account localization keys.
- `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`: add the three supported translations.
- `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift`: assert account UI layout contracts.
- `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`: update `AppLifecycle` ownership/restoration coverage without coupling authentication to `DownloadStore`.
- `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`: extend the exact visible-key inventory.
- `docs/swift-2.0/ARCHITECTURE.md`, `docs/swift-2.0/DEVELOPMENT.md`, `ENTITLEMENT_ARCHITECTURE.md`, `PRIVACY_DATA_MAP.md`, and `PRIVACY_THREAT_MODEL.md`: document implemented boundaries and future gates.

---

### Task 1: Authentication Domain And Fail-Closed Environment

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationModels.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/AuthenticationModelsTests.swift`

**Interfaces:**
- Consumes: `ProcessInfo.processInfo.environment` and `Date` only.
- Produces: `AuthEnvironment.resolve(from:)`, `AuthenticationProviderKind`, `MockPlanPreview`, `AccountSummary`, `StoredCredentialEnvelope`, `AuthenticationSession`, `AuthPresentationError`, and `AccountSessionState`.

- [ ] **Step 1: Write the failing domain tests**

```swift
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class AuthenticationModelsTests: XCTestCase {
    func testEnvironmentOnlyEnablesExactMockValue() {
        XCTAssertEqual(AuthEnvironment.resolve(from: [:]), .disabled)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": ""]), .disabled)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": "mock"]), .mock)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": "MOCK"]), .disabled)
        XCTAssertEqual(AuthEnvironment.resolve(from: ["YTDP_AUTH_MODE": "production"]), .disabled)
    }

    func testStoredEnvelopeCannotSerializeTheMemoryOnlyAccessToken() throws {
        let session = AuthenticationSession(
            summary: AccountSummary(
                provider: .google,
                accountID: "mock-account",
                displayName: "Demo User",
                planPreview: .pro,
                expiresAt: Date(timeIntervalSince1970: 2_000)
            ),
            accessToken: "memory-only-access",
            refreshCredential: "stored-refresh"
        )

        let data = try JSONEncoder().encode(session.storedEnvelope)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("memory-only-access"))
        XCTAssertTrue(text.contains("stored-refresh"))
    }
}
```

- [ ] **Step 2: Run the tests and verify the intended red state**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter AuthenticationModelsTests
```

Expected: compilation fails because the authentication domain types do not yet exist.

- [ ] **Step 3: Add the minimal domain types**

```swift
import Foundation

enum AuthEnvironment: String, Equatable, Hashable, Sendable {
    case disabled
    case mock

    static func resolve(from environment: [String: String] = ProcessInfo.processInfo.environment) -> AuthEnvironment {
        environment["YTDP_AUTH_MODE"] == "mock" ? .mock : .disabled
    }

    var storageNamespace: String { rawValue }
}

enum AuthenticationProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case google
    case apple
}

enum MockPlanPreview: String, Codable, Equatable, Sendable {
    case free
    case pro
}

struct AccountSummary: Codable, Equatable, Sendable {
    let provider: AuthenticationProviderKind
    let accountID: String
    let displayName: String
    let planPreview: MockPlanPreview
    let expiresAt: Date
}

struct StoredCredentialEnvelope: Codable, Equatable, Sendable {
    let summary: AccountSummary
    let refreshCredential: String
}

struct AuthenticationSession: Equatable, Sendable {
    let summary: AccountSummary
    let accessToken: String
    let refreshCredential: String

    var storedEnvelope: StoredCredentialEnvelope {
        StoredCredentialEnvelope(summary: summary, refreshCredential: refreshCredential)
    }
}

enum AuthPresentationError: String, Equatable, Sendable {
    case providerUnavailable
    case invalidSession
    case expiredSession
    case credentialStorageUnavailable
    case credentialRemovalFailed
    case signInFailed
}

enum AccountSessionState: Equatable, Sendable {
    case disabled
    case signedOut
    case signingIn(AuthenticationProviderKind)
    case restoring
    case signedIn(AccountSummary)
    case requiresReauthentication(AuthenticationProviderKind?)
    case failed(AuthPresentationError)
    case signingOut
}
```

- [ ] **Step 4: Run the focused tests**

Run the command from Step 2.

Expected: `AuthenticationModelsTests` passes with zero failures.

- [ ] **Step 5: Commit the domain boundary**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationModels.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/AuthenticationModelsTests.swift
git commit -m "feat(swift): define authentication domain"
```

### Task 2: Credential Vault And Device-Local Keychain

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/CredentialVault.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/KeychainCredentialVault.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/CredentialVaultTests.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/KeychainCredentialVaultTests.swift`

**Interfaces:**
- Consumes: `AuthEnvironment` and `StoredCredentialEnvelope` from Task 1.
- Produces: async `CredentialVault.load/save/delete`, `InMemoryCredentialVault`, `KeychainCredentialVault`, and `CredentialVaultError`.

- [ ] **Step 1: Write failing in-memory and Keychain tests**

```swift
import XCTest
@testable import YTDownloaderPro2

final class CredentialVaultTests: XCTestCase {
    func testInMemoryVaultKeepsOneEnvelopePerEnvironment() async throws {
        let vault = InMemoryCredentialVault()
        let first = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "first")
        let replacement = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "replacement")

        try await vault.save(first, environment: .mock)
        try await vault.save(replacement, environment: .mock)

        XCTAssertEqual(try await vault.load(environment: .mock), replacement)
        try await vault.delete(environment: .mock)
        XCTAssertNil(try await vault.load(environment: .mock))
    }
}

final class KeychainCredentialVaultTests: XCTestCase {
    func testRoundTripUsesDisposableServiceNamespace() async throws {
        guard ProcessInfo.processInfo.environment["YTDP_RUN_KEYCHAIN_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set YTDP_RUN_KEYCHAIN_INTEGRATION_TESTS=1 for the focused Keychain integration test")
        }
        let service = "com.catstayathome.YTDownloaderPro.tests.\(UUID().uuidString)"
        let vault = KeychainCredentialVault(servicePrefix: service)
        let envelope = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "round-trip")
        addTeardownBlock { try? await vault.delete(environment: .mock) }

        try await vault.save(envelope, environment: .mock)
        XCTAssertEqual(try await vault.load(environment: .mock), envelope)
        try await vault.delete(environment: .mock)
        XCTAssertNil(try await vault.load(environment: .mock))
    }
}
```

Add this exact fixture in `CredentialVaultTests.swift` below the test class:

```swift
extension StoredCredentialEnvelope {
    static func fixture(
        provider: AuthenticationProviderKind,
        refreshCredential: String,
        expiresAt: Date = Date(timeIntervalSince1970: 4_000)
    ) -> StoredCredentialEnvelope {
        StoredCredentialEnvelope(
            summary: AccountSummary(
                provider: provider,
                accountID: "mock-account",
                displayName: "Demo User",
                planPreview: .pro,
                expiresAt: expiresAt
            ),
            refreshCredential: refreshCredential
        )
    }
}
```

- [ ] **Step 2: Run the vault tests and confirm they fail to compile**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter CredentialVaultTests
```

Expected: compilation fails because `CredentialVault`, `InMemoryCredentialVault`, and `KeychainCredentialVault` do not exist.

- [ ] **Step 3: Implement the async vault boundary and Security.framework adapter**

Use this protocol and memory implementation:

```swift
import Foundation

protocol CredentialVault: Sendable {
    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope?
    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws
    func delete(environment: AuthEnvironment) async throws
}

actor InMemoryCredentialVault: CredentialVault {
    private var storage: [AuthEnvironment: StoredCredentialEnvelope] = [:]

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? { storage[environment] }
    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws { storage[environment] = envelope }
    func delete(environment: AuthEnvironment) async throws { storage[environment] = nil }
}
```

Use one generic-password item per environment in `KeychainCredentialVault`:

```swift
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
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(status) }
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
        let updateStatus = SecItemUpdate(baseQuery(environment: environment) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialVaultError.unexpectedStatus(updateStatus) }
        var add = baseQuery(environment: environment)
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(addStatus) }
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
```

- [ ] **Step 4: Run memory tests, then the explicit Keychain integration test**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter CredentialVaultTests

YTDP_RUN_KEYCHAIN_INTEGRATION_TESTS=1 \
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter KeychainCredentialVaultTests
```

Expected: both focused suites pass; cleanup leaves no item under the generated test service name.

- [ ] **Step 5: Commit the vault boundary**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Authentication/CredentialVault.swift \
  swift-2.0/Sources/YTDownloaderPro2/Authentication/KeychainCredentialVault.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/CredentialVaultTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/KeychainCredentialVaultTests.swift
git commit -m "feat(swift): add authentication credential vault"
```

### Task 3: Provider Contract And Local Mock Providers

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationProvider.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/MockAuthenticationProvider.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/MockAuthenticationProviderTests.swift`

**Interfaces:**
- Consumes: Task 1 session and envelope types.
- Produces: `AuthenticationProvider`, `AuthenticationProviderRegistry`, and `MockAuthenticationProvider` for `.google` and `.apple`.

- [ ] **Step 1: Write failing provider tests**

```swift
import Foundation
import XCTest
@testable import YTDownloaderPro2

final class MockAuthenticationProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testGoogleAndAppleCreateSyntheticSessionsWithoutRealIdentityFields() async throws {
        let now = now
        for kind in AuthenticationProviderKind.allCases {
            let provider = MockAuthenticationProvider(kind: kind, now: { now }, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! })
            let session = try await provider.signIn()
            XCTAssertEqual(session.summary.provider, kind)
            XCTAssertTrue(session.summary.accountID.hasPrefix("mock-"))
            XCTAssertFalse(session.summary.displayName.contains("@"))
            XCTAssertFalse(session.accessToken.isEmpty)
            XCTAssertFalse(session.refreshCredential.isEmpty)
            XCTAssertEqual(session.summary.planPreview, .pro)
        }
    }

    func testRestoreRejectsExpiredAndProviderMismatchedEnvelopes() async throws {
        let now = now
        let provider = MockAuthenticationProvider(kind: .google, now: { now })
        let expired = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "expired", expiresAt: now)
        let wrongProvider = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "wrong", expiresAt: now.addingTimeInterval(60))

        await XCTAssertThrowsAuthenticationError(.expiredSession) { try await provider.restore(from: expired) }
        await XCTAssertThrowsAuthenticationError(.invalidSession) { try await provider.restore(from: wrongProvider) }
    }
}
```

Define the async assertion helper in the same test file:

```swift
private func XCTAssertThrowsAuthenticationError<Value>(
    _ expected: AuthenticationProviderError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Value
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as AuthenticationProviderError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
```

- [ ] **Step 2: Run the provider tests and verify the red state**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter MockAuthenticationProviderTests
```

Expected: compilation fails because the provider protocol and mock implementation are missing.

- [ ] **Step 3: Implement the provider-only boundary**

```swift
import Foundation

enum AuthenticationProviderError: Error, Equatable, Sendable {
    case cancelled
    case invalidSession
    case expiredSession
}

protocol AuthenticationProvider: Sendable {
    var kind: AuthenticationProviderKind { get }
    func signIn() async throws -> AuthenticationSession
    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession
    func signOut(refreshCredential: String?) async
}

struct AuthenticationProviderRegistry: Sendable {
    private let providers: [AuthenticationProviderKind: any AuthenticationProvider]

    init(_ providers: [any AuthenticationProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.kind, $0) })
    }

    func provider(for kind: AuthenticationProviderKind) -> (any AuthenticationProvider)? {
        providers[kind]
    }

    static func mock() -> AuthenticationProviderRegistry {
        AuthenticationProviderRegistry(AuthenticationProviderKind.allCases.map { MockAuthenticationProvider(kind: $0) })
    }
}
```

Implement `MockAuthenticationProvider` as a value with injected `@Sendable` clock and UUID closures. `signIn()` creates only synthetic strings with the `mock-` prefix, a 30-day expiry, and `.pro` preview. `restore(from:)` checks exact provider match, non-empty opaque fields, and `expiresAt > now()`, then creates a new in-memory access token. `signOut` performs no I/O.

```swift
struct MockAuthenticationProvider: AuthenticationProvider {
    let kind: AuthenticationProviderKind
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        kind: AuthenticationProviderKind,
        now: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.kind = kind
        self.now = now
        self.makeUUID = makeUUID
    }

    func signIn() async throws -> AuthenticationSession {
        try Task.checkCancellation()
        let identifier = makeUUID().uuidString.lowercased()
        let summary = AccountSummary(
            provider: kind,
            accountID: "mock-\(kind.rawValue)-\(identifier)",
            displayName: kind == .google ? "Demo Google User" : "Demo Apple User",
            planPreview: .pro,
            expiresAt: now().addingTimeInterval(30 * 24 * 60 * 60)
        )
        return AuthenticationSession(
            summary: summary,
            accessToken: "mock-access-\(identifier)",
            refreshCredential: "mock-refresh-\(identifier)"
        )
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        try Task.checkCancellation()
        guard envelope.summary.provider == kind,
              !envelope.summary.accountID.isEmpty,
              !envelope.summary.displayName.isEmpty,
              !envelope.refreshCredential.isEmpty else {
            throw AuthenticationProviderError.invalidSession
        }
        guard envelope.summary.expiresAt > now() else {
            throw AuthenticationProviderError.expiredSession
        }
        return AuthenticationSession(
            summary: envelope.summary,
            accessToken: "mock-access-\(makeUUID().uuidString.lowercased())",
            refreshCredential: envelope.refreshCredential
        )
    }

    func signOut(refreshCredential: String?) async {
        // Phase 1 has no provider or network state to revoke.
    }
}
```

- [ ] **Step 4: Run provider tests**

Run the command from Step 2.

Expected: all mock provider tests pass and production source contains no `URLSession`, `ASWebAuthenticationSession`, Google endpoint, or Apple endpoint.

- [ ] **Step 5: Commit the provider contract**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationProvider.swift \
  swift-2.0/Sources/YTDownloaderPro2/Authentication/MockAuthenticationProvider.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/MockAuthenticationProviderTests.swift
git commit -m "feat(swift): add local mock authentication providers"
```

### Task 4: Serialized Account Session Store

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/AccountSessionStore.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift`

**Interfaces:**
- Consumes: `AuthEnvironment`, `CredentialVault`, `AuthenticationProviderRegistry`, provider session types.
- Produces: `@MainActor final class AccountSessionStore: ObservableObject` with `state`, `environment`, `signIn(with:)`, `restoreSession()`, `cancelAuthentication()`, and `signOut()`.

- [ ] **Step 1: Write failing happy-path and isolation tests**

```swift
@MainActor
final class AccountSessionStoreTests: XCTestCase {
    func testDisabledStoreNeverReadsVaultOrExposesAccountState() async {
        let vault = RecordingCredentialVault()
        let store = AccountSessionStore(environment: .disabled, vault: vault, providers: .init([]))

        await store.restoreSession()

        XCTAssertEqual(store.state, .disabled)
        XCTAssertEqual(await vault.operations, [])
    }

    func testSignInPersistsEnvelopeButKeepsAccessTokenOutOfVault() async throws {
        let vault = RecordingCredentialVault()
        let session = AuthenticationSession.fixture(provider: .google, accessToken: "memory-secret")
        let provider = ImmediateAuthenticationProvider(kind: .google, signInResult: .success(session))
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.signIn(with: .google)

        XCTAssertEqual(store.state, .signedIn(session.summary))
        let saved = try XCTUnwrap(await vault.savedEnvelope)
        XCTAssertEqual(saved, session.storedEnvelope)
        XCTAssertFalse(String(data: try JSONEncoder().encode(saved), encoding: .utf8)!.contains("memory-secret"))
    }

    func testRestoreAndSignOutUseOnlyAuthenticationStorage() async throws {
        let envelope = StoredCredentialEnvelope.fixture(provider: .apple, refreshCredential: "restore")
        let vault = RecordingCredentialVault(initial: envelope)
        let provider = ImmediateAuthenticationProvider(kind: .apple, restoreResult: .success(.fixture(provider: .apple)))
        let store = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))

        await store.restoreSession()
        XCTAssertEqual(store.state, .signedIn(.fixture(provider: .apple)))
        await store.signOut()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(await vault.operations, [.load(.mock), .delete(.mock)])
    }
}
```

In `AuthenticationFixtures.swift`, define these test doubles and fixtures:

```swift
import Foundation
@testable import YTDownloaderPro2

enum VaultOperation: Equatable, Sendable {
    case load(AuthEnvironment)
    case save(AuthEnvironment)
    case delete(AuthEnvironment)
}

actor RecordingCredentialVault: CredentialVault {
    private(set) var operations: [VaultOperation] = []
    private(set) var savedEnvelope: StoredCredentialEnvelope?
    private var storedEnvelope: StoredCredentialEnvelope?
    private let loadError: CredentialVaultError?
    private let saveError: CredentialVaultError?
    private let deleteError: CredentialVaultError?

    init(
        initial: StoredCredentialEnvelope? = nil,
        loadError: CredentialVaultError? = nil,
        saveError: CredentialVaultError? = nil,
        deleteError: CredentialVaultError? = nil
    ) {
        storedEnvelope = initial
        self.loadError = loadError
        self.saveError = saveError
        self.deleteError = deleteError
    }

    func load(environment: AuthEnvironment) async throws -> StoredCredentialEnvelope? {
        operations.append(.load(environment))
        if let loadError { throw loadError }
        return storedEnvelope
    }

    func save(_ envelope: StoredCredentialEnvelope, environment: AuthEnvironment) async throws {
        operations.append(.save(environment))
        if let saveError { throw saveError }
        storedEnvelope = envelope
        savedEnvelope = envelope
    }

    func delete(environment: AuthEnvironment) async throws {
        operations.append(.delete(environment))
        if let deleteError { throw deleteError }
        storedEnvelope = nil
    }
}

actor AuthenticationCallCounter {
    private(set) var signOutCount = 0
    func recordSignOut() { signOutCount += 1 }
}

struct ImmediateAuthenticationProvider: AuthenticationProvider {
    let kind: AuthenticationProviderKind
    let signInResult: Result<AuthenticationSession, AuthenticationProviderError>
    let restoreResult: Result<AuthenticationSession, AuthenticationProviderError>
    let counter: AuthenticationCallCounter

    init(
        kind: AuthenticationProviderKind,
        signInResult: Result<AuthenticationSession, AuthenticationProviderError> = .failure(.cancelled),
        restoreResult: Result<AuthenticationSession, AuthenticationProviderError> = .failure(.invalidSession),
        counter: AuthenticationCallCounter = AuthenticationCallCounter()
    ) {
        self.kind = kind
        self.signInResult = signInResult
        self.restoreResult = restoreResult
        self.counter = counter
    }

    func signIn() async throws -> AuthenticationSession { try signInResult.get() }
    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession { try restoreResult.get() }
    func signOut(refreshCredential: String?) async { await counter.recordSignOut() }
}

extension AccountSummary {
    static func fixture(provider: AuthenticationProviderKind) -> AccountSummary {
        AccountSummary(
            provider: provider,
            accountID: "mock-account",
            displayName: "Demo User",
            planPreview: .pro,
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }
}

extension AuthenticationSession {
    static func fixture(
        provider: AuthenticationProviderKind,
        accessToken: String = "memory-access"
    ) -> AuthenticationSession {
        AuthenticationSession(
            summary: .fixture(provider: provider),
            accessToken: accessToken,
            refreshCredential: "mock-refresh"
        )
    }
}
```

- [ ] **Step 2: Run the session-store tests and verify the red state**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter AccountSessionStoreTests
```

Expected: compilation fails because `AccountSessionStore` is missing.

- [ ] **Step 3: Implement the state owner and one-flight operation model**

Use this public shape:

```swift
import Combine
import Foundation

@MainActor
final class AccountSessionStore: ObservableObject {
    @Published private(set) var state: AccountSessionState
    let environment: AuthEnvironment

    private let vault: any CredentialVault
    private let providers: AuthenticationProviderRegistry
    private let now: @Sendable () -> Date
    private var accessToken: String?
    private var refreshCredential: String?
    private var currentSummary: AccountSummary?
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var activePriorState: AccountSessionState?
    private var activeProviderTask: Task<AuthenticationSession, Error>?

    init(
        environment: AuthEnvironment,
        vault: any CredentialVault,
        providers: AuthenticationProviderRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.vault = vault
        self.providers = providers
        self.now = now
        self.state = environment == .disabled ? .disabled : .signedOut
    }

    static func live(environment: AuthEnvironment = .resolve()) -> AccountSessionStore {
        AccountSessionStore(
            environment: environment,
            vault: KeychainCredentialVault(),
            providers: environment == .mock ? .mock() : .init([])
        )
    }
}
```

Use these operation and validation helpers. Every path that resumes after an
`await` must call `owns(_:)` before publishing state:

```swift
private func beginOperation() -> (UInt64, AccountSessionState)? {
    guard activeOperationID == nil else { return nil }
    nextOperationID &+= 1
    activeOperationID = nextOperationID
    activePriorState = state
    return (nextOperationID, state)
}

private func owns(_ id: UInt64) -> Bool { activeOperationID == id }

private func finishOperation(_ id: UInt64, state newState: AccountSessionState) {
    guard owns(id) else { return }
    activeOperationID = nil
    activePriorState = nil
    activeProviderTask = nil
    state = newState
}

private func validate(_ session: AuthenticationSession, provider: AuthenticationProviderKind) throws {
    guard session.summary.provider == provider,
          !session.summary.accountID.isEmpty,
          !session.summary.displayName.isEmpty,
          !session.accessToken.isEmpty,
          !session.refreshCredential.isEmpty else {
        throw AuthenticationProviderError.invalidSession
    }
    guard session.summary.expiresAt > now() else {
        throw AuthenticationProviderError.expiredSession
    }
}

private func presentationError(for error: Error) -> AuthPresentationError {
    switch error {
    case AuthenticationProviderError.invalidSession: .invalidSession
    case AuthenticationProviderError.expiredSession: .expiredSession
    case is CredentialVaultError: .credentialStorageUnavailable
    default: .signInFailed
    }
}
```

Implement the public operations with this exact ownership order:

```swift
func signIn(with kind: AuthenticationProviderKind) async {
    guard environment == .mock,
          let provider = providers.provider(for: kind) else {
        if environment == .mock { state = .failed(.providerUnavailable) }
        return
    }
    guard let (operationID, priorState) = beginOperation() else { return }
    state = .signingIn(kind)
    let task = Task { try await provider.signIn() }
    activeProviderTask = task
    let result = await task.result
    guard owns(operationID) else { return }

    do {
        let session = try result.get()
        try validate(session, provider: kind)
        try await vault.save(session.storedEnvelope, environment: environment)
        guard owns(operationID) else { return }
        accessToken = session.accessToken
        refreshCredential = session.refreshCredential
        currentSummary = session.summary
        finishOperation(operationID, state: .signedIn(session.summary))
    } catch is CancellationError {
        finishOperation(operationID, state: priorState)
    } catch AuthenticationProviderError.cancelled {
        finishOperation(operationID, state: priorState)
    } catch {
        finishOperation(operationID, state: .failed(presentationError(for: error)))
    }
}

func restoreSession() async {
    guard environment == .mock else {
        state = .disabled
        return
    }
    guard let (operationID, priorState) = beginOperation() else { return }
    state = .restoring
    var restoringProvider: AuthenticationProviderKind?

    do {
        guard let envelope = try await vault.load(environment: environment) else {
            finishOperation(operationID, state: .signedOut)
            return
        }
        restoringProvider = envelope.summary.provider
        guard owns(operationID),
              let provider = providers.provider(for: envelope.summary.provider) else {
            if owns(operationID) { finishOperation(operationID, state: .requiresReauthentication(nil)) }
            return
        }
        let task = Task { try await provider.restore(from: envelope) }
        activeProviderTask = task
        let session = try await task.value
        guard owns(operationID) else { return }
        try validate(session, provider: envelope.summary.provider)
        accessToken = session.accessToken
        refreshCredential = session.refreshCredential
        currentSummary = session.summary
        finishOperation(operationID, state: .signedIn(session.summary))
    } catch is CancellationError {
        finishOperation(operationID, state: priorState)
    } catch AuthenticationProviderError.cancelled {
        finishOperation(operationID, state: priorState)
    } catch AuthenticationProviderError.expiredSession {
        finishOperation(operationID, state: .requiresReauthentication(restoringProvider))
    } catch AuthenticationProviderError.invalidSession {
        do {
            try await vault.delete(environment: environment)
        } catch {
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .failed(.credentialRemovalFailed))
            return
        }
        guard owns(operationID) else { return }
        finishOperation(operationID, state: .requiresReauthentication(nil))
    } catch CredentialVaultError.malformedRecord {
        do {
            try await vault.delete(environment: environment)
        } catch {
            guard owns(operationID) else { return }
            finishOperation(operationID, state: .failed(.credentialRemovalFailed))
            return
        }
        guard owns(operationID) else { return }
        finishOperation(operationID, state: .requiresReauthentication(nil))
    } catch {
        finishOperation(operationID, state: .failed(.credentialStorageUnavailable))
    }
}

func cancelAuthentication() {
    let isCancellable = switch state {
    case .signingIn, .restoring: true
    default: false
    }
    guard isCancellable, let operationID = activeOperationID else { return }
    let priorState = activePriorState ?? (environment == .disabled ? .disabled : .signedOut)
    activeProviderTask?.cancel()
    finishOperation(operationID, state: priorState)
}

func signOut() async {
    guard environment == .mock, activeOperationID == nil,
          let summary = currentSummary else { return }
    guard let (operationID, _) = beginOperation() else { return }
    state = .signingOut
    let credential = refreshCredential
    accessToken = nil
    await providers.provider(for: summary.provider)?.signOut(refreshCredential: credential)
    guard owns(operationID) else { return }
    do {
        try await vault.delete(environment: environment)
        guard owns(operationID) else { return }
        refreshCredential = nil
        currentSummary = nil
        finishOperation(operationID, state: .signedOut)
    } catch {
        finishOperation(operationID, state: .failed(.credentialRemovalFailed))
    }
}
```

Use the injected `now` closure in expiry tests so the store and providers share
the same deterministic clock.

- [ ] **Step 4: Run focused tests**

Run the command from Step 2.

Expected: disabled, sign-in, restoration, and sign-out tests pass with zero failures.

- [ ] **Step 5: Commit the session owner**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Authentication/AccountSessionStore.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift
git commit -m "feat(swift): manage mock account sessions"
```

### Task 5: Cancellation, Race Safety, And Payload-Free Diagnostics

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationDiagnostics.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Authentication/AccountSessionStore.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift`

**Interfaces:**
- Consumes: Task 4 state machine.
- Produces: `AuthenticationDiagnosticEvent`, `AuthenticationDiagnosticsRecording`, `SystemAuthenticationDiagnosticsRecorder`, and race-safe cancellation behavior.

- [ ] **Step 1: Add failing cancellation, stale-result, and diagnostics tests**

```swift
func testCancellationRestoresPriorStableStateEvenWhenProviderFinishesLater() async throws {
    let provider = ControlledAuthenticationProvider(kind: .google)
    let diagnostics = RecordingAuthenticationDiagnostics()
    let store = AccountSessionStore.fixture(provider: provider, diagnostics: diagnostics)
    let signIn = Task { await store.signIn(with: .google) }
    await provider.waitUntilSignInStarts()

    store.cancelAuthentication()
    await provider.finishSignIn(.success(.fixture(provider: .google)))
    await signIn.value

    XCTAssertEqual(store.state, .signedOut)
    XCTAssertEqual(await diagnostics.events, [.signInStarted, .signInCancelled])
}

func testRapidDuplicateSignInStartsOnlyOneProviderOperation() async {
    let provider = ControlledAuthenticationProvider(kind: .google)
    let store = AccountSessionStore.fixture(provider: provider)
    async let first: Void = store.signIn(with: .google)
    async let second: Void = store.signIn(with: .google)
    await provider.waitUntilSignInStarts()
    XCTAssertEqual(await provider.signInCallCount, 1)
    await provider.finishSignIn(.failure(AuthenticationProviderError.cancelled))
    _ = await (first, second)
}

func testDiagnosticEventEncodingHasNoPayloadFields() throws {
    for event in AuthenticationDiagnosticEvent.allCases {
        let data = try JSONEncoder().encode(event)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("account"))
        XCTAssertFalse(text.contains("email"))
        XCTAssertFalse(text.contains("@"))
    }
}
```

Add these controlled doubles to `AuthenticationFixtures.swift`. The provider
deliberately uses a continuation so tests can finish it after cancellation and
prove stale completions are ignored:

```swift
actor ControlledAuthenticationProvider: AuthenticationProvider {
    nonisolated let kind: AuthenticationProviderKind
    private(set) var signInCallCount = 0
    private var continuation: CheckedContinuation<AuthenticationSession, Error>?

    init(kind: AuthenticationProviderKind) { self.kind = kind }

    func signIn() async throws -> AuthenticationSession {
        signInCallCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func restore(from envelope: StoredCredentialEnvelope) async throws -> AuthenticationSession {
        throw AuthenticationProviderError.invalidSession
    }

    func signOut(refreshCredential: String?) async {}

    func waitUntilSignInStarts() async {
        while signInCallCount == 0 { await Task.yield() }
    }

    func finishSignIn(_ result: Result<AuthenticationSession, AuthenticationProviderError>) {
        let pending = continuation
        continuation = nil
        switch result {
        case let .success(session): pending?.resume(returning: session)
        case let .failure(error): pending?.resume(throwing: error)
        }
    }
}

actor RecordingAuthenticationDiagnostics: AuthenticationDiagnosticsRecording {
    private(set) var events: [AuthenticationDiagnosticEvent] = []
    func record(_ event: AuthenticationDiagnosticEvent) async { events.append(event) }
}

extension AccountSessionStore {
    static func fixture(
        provider: any AuthenticationProvider,
        diagnostics: any AuthenticationDiagnosticsRecording = RecordingAuthenticationDiagnostics()
    ) -> AccountSessionStore {
        AccountSessionStore(
            environment: .mock,
            vault: RecordingCredentialVault(),
            providers: .init([provider]),
            now: { Date(timeIntervalSince1970: 1_000) },
            diagnostics: diagnostics
        )
    }
}
```

- [ ] **Step 2: Run the focused suite and confirm the new assertions fail**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter AccountSessionStoreTests
```

Expected: compilation fails for missing diagnostics types or behavioral tests fail because cancellation and duplicate operations are not yet protected.

- [ ] **Step 3: Add finite diagnostics and generation ownership checks**

```swift
import OSLog

enum AuthenticationDiagnosticEvent: String, Codable, CaseIterable, Sendable {
    case signInStarted = "auth.sign-in.started"
    case signInCancelled = "auth.sign-in.cancelled"
    case signInFailed = "auth.sign-in.failed"
    case sessionRestored = "auth.session.restored"
    case sessionExpired = "auth.session.expired"
    case storageUnavailable = "auth.storage.unavailable"
    case signOutCompleted = "auth.sign-out.completed"
}

protocol AuthenticationDiagnosticsRecording: Sendable {
    func record(_ event: AuthenticationDiagnosticEvent) async
}

struct SystemAuthenticationDiagnosticsRecorder: AuthenticationDiagnosticsRecording {
    private let logger = Logger(subsystem: "com.catstayathome.YTDownloaderPro", category: "Authentication")
    func record(_ event: AuthenticationDiagnosticEvent) async {
        logger.info("\(event.rawValue, privacy: .public)")
    }
}
```

Inject `diagnostics: any AuthenticationDiagnosticsRecording` into the store,
defaulting to `SystemAuthenticationDiagnosticsRecorder()`. Do not add a method
that accepts arbitrary strings. Before every async completion changes state,
require exact operation-ID ownership. `cancelAuthentication()` increments the
generation, cancels `activeProviderTask`, clears `activeOperationID`, restores
its prior stable state, and records only `.signInCancelled` when applicable.

- [ ] **Step 4: Run strict focused tests**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter AccountSessionStoreTests
```

Expected: all session-store tests pass under complete strict concurrency.

- [ ] **Step 5: Commit the safety boundary**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Authentication/AuthenticationDiagnostics.swift \
  swift-2.0/Sources/YTDownloaderPro2/Authentication/AccountSessionStore.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/AccountSessionStoreTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/AuthenticationFixtures.swift
git commit -m "fix(swift): serialize authentication state changes"
```

### Task 6: Localized Account Presentation Contracts

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/AccountPresentation.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/AccountPresentationTests.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `AuthEnvironment`, `AccountSessionState`, and existing `L10n`.
- Produces: `AccountSidebarPresentation.make(environment:state:locale:)` and `AccountSettingsPresentation.make(environment:state:locale:)` for the views in Task 7.

- [ ] **Step 1: Write failing presentation and localization inventory tests**

```swift
final class AccountPresentationTests: XCTestCase {
    func testDisabledModeHidesEveryAccountSurface() {
        let sidebar = AccountSidebarPresentation.make(environment: .disabled, state: .disabled, locale: Locale(identifier: "zh-Hant"))
        let settings = AccountSettingsPresentation.make(environment: .disabled, state: .disabled, locale: Locale(identifier: "zh-Hant"))
        XCTAssertFalse(sidebar.isVisible)
        XCTAssertFalse(settings.isVisible)
    }

    func testSignedInSidebarUsesSyntheticNameAndTestPlan() {
        let summary = AccountSummary.fixture(provider: .google)
        let value = AccountSidebarPresentation.make(environment: .mock, state: .signedIn(summary), locale: Locale(identifier: "zh-Hant"))
        XCTAssertEqual(value.title, summary.displayName)
        XCTAssertEqual(value.subtitle, "測試 Pro · Google")
        XCTAssertFalse(value.showsProgress)
    }

    func testSigningInAndExpiredStatesKeepDownloadsAvailable() {
        let locale = Locale(identifier: "en")
        XCTAssertEqual(AccountSidebarPresentation.make(environment: .mock, state: .signingIn(.apple), locale: locale).subtitle, "Downloads are unaffected")
        XCTAssertEqual(AccountSidebarPresentation.make(environment: .mock, state: .requiresReauthentication(.apple), locale: locale).subtitle, "Free downloads remain available")
    }
}
```

Extend `LocalizationTests.testVisibleKeyInventoryIsExplicitAndComplete()` with
the exact raw keys listed in Step 3, then rely on the existing catalog test to
require all three locales.

- [ ] **Step 2: Run presentation and localization tests to verify red**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter AccountPresentationTests

CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter LocalizationTests
```

Expected: the presentation types and account localization keys are missing.

- [ ] **Step 3: Add exact account keys, translations, and pure mappings**

Add these `L10n.Key` cases and raw values:

```swift
case accountSettingsTitle = "account.settings.title"
case accountDevelopmentMode = "account.developmentMode"
case accountSignInPrompt = "account.signIn.prompt"
case accountSignInOrViewPlans = "account.signInOrViewPlans"
case accountSignInGoogle = "account.signIn.google"
case accountSignInApple = "account.signIn.apple"
case accountFreeNoSignIn = "account.free.noSignIn"
case accountCurrentPlan = "account.currentPlan"
case accountFreePlan = "account.plan.free"
case accountTestProPlan = "account.plan.testPro"
case accountSigningIn = "account.signingIn"
case accountRestoring = "account.restoring"
case accountDownloadsUnaffected = "account.downloadsUnaffected"
case accountReauthenticate = "account.reauthenticate"
case accountFreeStillAvailable = "account.freeStillAvailable"
case accountUnavailable = "account.unavailable"
case accountOpenSettingsRetry = "account.openSettingsRetry"
case accountRetry = "account.retry"
case accountSignOut = "account.signOut"
case accountSignOutPreservesData = "account.signOut.preservesData"
case accountProviderGoogle = "account.provider.google"
case accountProviderApple = "account.provider.apple"
case accountErrorProviderUnavailable = "account.error.providerUnavailable"
case accountErrorInvalidSession = "account.error.invalidSession"
case accountErrorExpiredSession = "account.error.expiredSession"
case accountErrorStorageUnavailable = "account.error.storageUnavailable"
case accountErrorRemovalFailed = "account.error.removalFailed"
case accountErrorSignInFailed = "account.error.signInFailed"
```

Add these exact values to `Localizable.xcstrings`:

| Raw key | English | Traditional Chinese | Japanese |
| --- | --- | --- | --- |
| `account.settings.title` | Account & Plan | 帳號與方案 | アカウントとプラン |
| `account.developmentMode` | Development Test Mode: no connection to Google, Apple, or production services. | 開發測試模式：不會連線至 Google、Apple 或正式服務。 | 開発テストモード：Google、Apple、正式サービスには接続しません。 |
| `account.signIn.prompt` | Sign in | 登入帳號 | サインイン |
| `account.signInOrViewPlans` | Sign in or view plans | 登入或查看方案 | サインインまたはプランを確認 |
| `account.signIn.google` | Sign in with Google | 使用 Google 登入 | Google でサインイン |
| `account.signIn.apple` | Sign in with Apple | 使用 Apple 登入 | Apple でサインイン |
| `account.free.noSignIn` | Free; no sign-in required | 免費版 · 免登入可用 | 無料版・サインイン不要 |
| `account.currentPlan` | Current plan | 目前方案 | 現在のプラン |
| `account.plan.free` | Free | 免費版 | 無料版 |
| `account.plan.testPro` | Test Pro | 測試 Pro | テスト Pro |
| `account.signingIn` | Signing in | 正在登入 | サインイン中 |
| `account.restoring` | Restoring account | 正在還原帳號 | アカウントを復元中 |
| `account.downloadsUnaffected` | Downloads are unaffected | 下載不受影響 | ダウンロードには影響しません |
| `account.reauthenticate` | Sign in again | 需要重新登入 | もう一度サインイン |
| `account.freeStillAvailable` | Free downloads remain available | 免費下載仍可使用 | 無料ダウンロードは引き続き利用できます |
| `account.unavailable` | Account unavailable | 帳號暫時無法使用 | アカウントを利用できません |
| `account.openSettingsRetry` | Open Settings to retry | 開啟設定以重試 | 設定を開いて再試行 |
| `account.retry` | Retry | 重試 | 再試行 |
| `account.signOut` | Sign Out | 登出 | サインアウト |
| `account.signOut.preservesData` | Signing out keeps downloads, history, media, and settings. | 登出會保留下載、紀錄、媒體與設定。 | サインアウトしてもダウンロード、履歴、メディア、設定は保持されます。 |
| `account.provider.google` | Google | Google | Google |
| `account.provider.apple` | Apple | Apple | Apple |
| `account.error.providerUnavailable` | This sign-in option is unavailable. | 此登入方式目前無法使用。 | このサインイン方法は利用できません。 |
| `account.error.invalidSession` | The saved account session is invalid. Sign in again. | 儲存的帳號工作階段無效，請重新登入。 | 保存されたアカウントセッションは無効です。もう一度サインインしてください。 |
| `account.error.expiredSession` | The account session has expired. Sign in again. | 帳號工作階段已過期，請重新登入。 | アカウントセッションの有効期限が切れました。もう一度サインインしてください。 |
| `account.error.storageUnavailable` | The account session could not be saved securely on this Mac. | 無法在這台 Mac 上安全儲存帳號工作階段。 | この Mac にアカウントセッションを安全に保存できませんでした。 |
| `account.error.removalFailed` | The saved account session could not be removed. Try signing out again. | 無法移除儲存的帳號工作階段，請再次登出。 | 保存されたアカウントセッションを削除できませんでした。もう一度サインアウトしてください。 |
| `account.error.signInFailed` | Sign-in could not be completed. Try again. | 無法完成登入，請重試。 | サインインを完了できませんでした。もう一度お試しください。 |

Implement the pure view contracts with this shape and exhaustive state mapping:

```swift
struct AccountSidebarPresentation: Equatable {
    let isVisible: Bool
    let title: String
    let subtitle: String
    let systemImage: String
    let showsProgress: Bool

    static func make(environment: AuthEnvironment, state: AccountSessionState, locale: Locale) -> Self {
        guard environment == .mock else {
            return .init(isVisible: false, title: "", subtitle: "", systemImage: "person.crop.circle", showsProgress: false)
        }
        switch state {
        case .disabled:
            return .init(isVisible: false, title: "", subtitle: "", systemImage: "person.crop.circle", showsProgress: false)
        case .signedOut:
            return .init(isVisible: true, title: L10n.string(.accountSignInOrViewPlans, locale: locale), subtitle: L10n.string(.accountFreeNoSignIn, locale: locale), systemImage: "person.crop.circle", showsProgress: false)
        case let .signingIn(provider):
            return .init(isVisible: true, title: L10n.string(.accountSigningIn, locale: locale), subtitle: L10n.string(.accountDownloadsUnaffected, locale: locale), systemImage: provider.systemImage, showsProgress: true)
        case .restoring:
            return .init(isVisible: true, title: L10n.string(.accountRestoring, locale: locale), subtitle: L10n.string(.accountDownloadsUnaffected, locale: locale), systemImage: "person.crop.circle", showsProgress: true)
        case let .signedIn(summary):
            let provider = L10n.string(summary.provider.localizationKey, locale: locale)
            let plan = L10n.string(summary.planPreview.localizationKey, locale: locale)
            return .init(isVisible: true, title: summary.displayName, subtitle: "\(plan) · \(provider)", systemImage: summary.provider.systemImage, showsProgress: false)
        case .requiresReauthentication:
            return .init(isVisible: true, title: L10n.string(.accountReauthenticate, locale: locale), subtitle: L10n.string(.accountFreeStillAvailable, locale: locale), systemImage: "person.crop.circle.badge.exclamationmark", showsProgress: false)
        case .failed:
            return .init(isVisible: true, title: L10n.string(.accountUnavailable, locale: locale), subtitle: L10n.string(.accountOpenSettingsRetry, locale: locale), systemImage: "exclamationmark.circle", showsProgress: false)
        case .signingOut:
            return .init(isVisible: true, title: L10n.string(.accountSignOut, locale: locale), subtitle: L10n.string(.accountDownloadsUnaffected, locale: locale), systemImage: "person.crop.circle", showsProgress: true)
        }
    }
}

struct AccountSettingsPresentation: Equatable {
    enum Content: Equatable {
        case signedOut
        case operation(title: String)
        case signedIn(AccountSummary)
        case reauthentication(AuthenticationProviderKind?)
        case failure(message: String, retriesSignOut: Bool)
    }

    let isVisible: Bool
    let developmentNotice: String
    let content: Content

    static func make(environment: AuthEnvironment, state: AccountSessionState, locale: Locale) -> Self {
        guard environment == .mock else {
            return .init(isVisible: false, developmentNotice: "", content: .signedOut)
        }
        let notice = L10n.string(.accountDevelopmentMode, locale: locale)
        switch state {
        case .disabled:
            return .init(isVisible: false, developmentNotice: "", content: .signedOut)
        case .signedOut:
            return .init(isVisible: true, developmentNotice: notice, content: .signedOut)
        case .signingIn:
            return .init(isVisible: true, developmentNotice: notice, content: .operation(title: L10n.string(.accountSigningIn, locale: locale)))
        case .restoring:
            return .init(isVisible: true, developmentNotice: notice, content: .operation(title: L10n.string(.accountRestoring, locale: locale)))
        case let .signedIn(summary):
            return .init(isVisible: true, developmentNotice: notice, content: .signedIn(summary))
        case let .requiresReauthentication(provider):
            return .init(isVisible: true, developmentNotice: notice, content: .reauthentication(provider))
        case let .failed(error):
            return .init(
                isVisible: true,
                developmentNotice: notice,
                content: .failure(
                    message: L10n.string(error.localizationKey, locale: locale),
                    retriesSignOut: error == .credentialRemovalFailed
                )
            )
        case .signingOut:
            return .init(isVisible: true, developmentNotice: notice, content: .operation(title: L10n.string(.accountSignOut, locale: locale)))
        }
    }
}

extension AuthenticationProviderKind {
    var localizationKey: L10n.Key { self == .google ? .accountProviderGoogle : .accountProviderApple }
    var systemImage: String { self == .apple ? "apple.logo" : "person.crop.circle" }
}

extension MockPlanPreview {
    var localizationKey: L10n.Key { self == .pro ? .accountTestProPlan : .accountFreePlan }
}

extension AuthPresentationError {
    var localizationKey: L10n.Key {
        switch self {
        case .providerUnavailable: .accountErrorProviderUnavailable
        case .invalidSession: .accountErrorInvalidSession
        case .expiredSession: .accountErrorExpiredSession
        case .credentialStorageUnavailable: .accountErrorStorageUnavailable
        case .credentialRemovalFailed: .accountErrorRemovalFailed
        case .signInFailed: .accountErrorSignInFailed
        }
    }
}
```

Never use `Error.localizedDescription` in either presentation contract.

- [ ] **Step 4: Run both focused suites**

Run both commands from Step 2.

Expected: account presentation tests pass, and `LocalizationTests` confirms the
entire key inventory exists in English, Japanese, and Traditional Chinese.

- [ ] **Step 5: Commit presentation contracts and strings**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Views/AccountPresentation.swift \
  swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift \
  swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings \
  swift-2.0/Tests/YTDownloaderPro2Tests/AccountPresentationTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift
git commit -m "feat(swift): localize account presentation"
```

### Task 7: Sidebar, Settings, And App Lifecycle Integration

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/AccountSidebarView.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/AccountSettingsSection.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift:319-507`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift:3-59`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift:162-173,1600-1608`

**Interfaces:**
- Consumes: Task 4 `AccountSessionStore` and Task 6 presentation contracts.
- Produces: conditional account UI and automatic mock-session restoration; preserves all existing download actions.

- [ ] **Step 1: Write failing lifecycle and layout-contract tests**

Add to `DownloadStoreTests`:

```swift
func testAppLifecycleOwnsBothStoresAndStartsMockRestoration() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let envelope = StoredCredentialEnvelope.fixture(provider: .google, refreshCredential: "restore")
    let vault = RecordingCredentialVault(initial: envelope)
    let provider = ImmediateAuthenticationProvider(kind: .google, restoreResult: .success(.fixture(provider: .google)))
    let accountStore = AccountSessionStore(environment: .mock, vault: vault, providers: .init([provider]))
    let lifecycle = AppLifecycle(store: fixture.store, accountSessionStore: accountStore)

    lifecycle.startAuthenticationRestoration()
    try await waitUntil("mock session restoration") {
        if case .signedIn = accountStore.state { return true }
        return false
    }

    XCTAssertTrue(lifecycle.store === fixture.store)
    XCTAssertTrue(lifecycle.accountSessionStore === accountStore)
}
```

Add a layout contract in `DownloadCenterViewTests`:

```swift
func testAccountEntryIsBottomAnchoredAndNeverPartOfDownloadSelection() {
    XCTAssertTrue(AccountSidebarLayout.isBottomAnchored)
    XCTAssertTrue(AccountSidebarLayout.isOutsideDownloadListSelection)
    XCTAssertEqual(AccountSidebarLayout.minimumHeight, 56)
}
```

- [ ] **Step 2: Run focused tests and confirm red**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox --filter 'DownloadStoreTests|DownloadCenterViewTests'
```

Expected: tests fail because `AppLifecycle` does not own an account store and
the sidebar layout contract does not exist.

- [ ] **Step 3: Wire views and lifecycle without touching download behavior**

Change `AppLifecycle` to own both stores:

```swift
let store: DownloadStore
let accountSessionStore: AccountSessionStore

override convenience init() {
    self.init(store: DownloadStore.live(), accountSessionStore: .live())
}

init(store: DownloadStore, accountSessionStore: AccountSessionStore? = nil) {
    self.store = store
    self.accountSessionStore = accountSessionStore ?? AccountSessionStore(
        environment: .disabled,
        vault: InMemoryCredentialVault(),
        providers: .init([])
    )
    super.init()
}

func startAuthenticationRestoration() {
    Task { @MainActor [accountSessionStore] in
        await accountSessionStore.restoreSession()
    }
}
```

Call `startAuthenticationRestoration()` from
`applicationDidFinishLaunching(_:)`. Inject
`.environmentObject(appLifecycle.accountSessionStore)` into both the main and
Settings scenes beside the existing `DownloadStore` injection.

Define the layout contract exactly as follows, then build `AccountSidebarView`
from `AccountSidebarPresentation`, using `SettingsLink` on
macOS 14+ and `SettingsWindowLauncher.openLegacy()` on macOS 13. Use SF Symbols,
tooltips, and accessibility labels. Show a `ProgressView` for signing-in and
restoring states.

```swift
enum AccountSidebarLayout {
    static let isBottomAnchored = true
    static let isOutsideDownloadListSelection = true
    static let minimumHeight: CGFloat = 56
}
```

Replace the current sidebar's top-level `List` with a `VStack(spacing: 0)` that
keeps the unchanged download `List` first and conditionally appends a divider
and `AccountSidebarView` only when its presentation says `isVisible`. The
account control must not receive a `DownloadStatus.SidebarSection` tag.

At the start of the existing `SettingsView` form, conditionally render
`AccountSettingsSection` when mock presentation is visible. Its Google and
Apple buttons call:

```swift
Task { await accountSessionStore.signIn(with: .google) }
Task { await accountSessionStore.signIn(with: .apple) }
Task { await accountSessionStore.signOut() }
accountSessionStore.cancelAuthentication()
```

Disable both provider buttons while an operation is active. Display the mock
mode notice persistently. Display only synthetic summary fields, app-owned
localized errors, and the explicit sign-out preservation note. Do not add a
confirmation dialog because sign-out does not delete local data.

Give every icon-only control a localized `.help` and `.accessibilityLabel`.
Expose operation progress to VoiceOver with the localized operation title, keep
Google/Apple/sign-out/retry controls in visual focus order, and return focus to
the initiating account control when a sheet or cancellable operation closes.

- [ ] **Step 4: Run focused strict tests and build**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors \
  --filter 'AccountPresentationTests|AccountSessionStoreTests|DownloadStoreTests|DownloadCenterViewTests|LocalizationTests'

CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift build --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: all focused tests pass and the debug executable builds with zero warnings.

- [ ] **Step 5: Commit app integration**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views/AccountSidebarView.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views/AccountSettingsSection.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift
git commit -m "feat(swift): add mock account surfaces"
```

### Task 8: Maintenance Documentation And Full Verification

**Files:**
- Create: `docs/swift-2.0/AUTHENTICATION.md`
- Modify: `docs/swift-2.0/ARCHITECTURE.md`
- Modify: `docs/swift-2.0/DEVELOPMENT.md`
- Modify: `ENTITLEMENT_ARCHITECTURE.md`
- Modify: `PRIVACY_DATA_MAP.md`
- Modify: `PRIVACY_THREAT_MODEL.md`

**Interfaces:**
- Consumes: all implemented behavior from Tasks 1-7.
- Produces: maintainer-facing operating instructions and final verification evidence; no new runtime API.

- [ ] **Step 1: Add a documentation contract check before writing docs**

Run this inventory and save its output in the implementation notes for review:

```bash
for path in \
  docs/swift-2.0/AUTHENTICATION.md \
  docs/swift-2.0/ARCHITECTURE.md \
  docs/swift-2.0/DEVELOPMENT.md \
  ENTITLEMENT_ARCHITECTURE.md \
  PRIVACY_DATA_MAP.md \
  PRIVACY_THREAT_MODEL.md; do
  test -f "$path" || printf 'missing: %s\n' "$path"
done
```

Expected before documentation: only `docs/swift-2.0/AUTHENTICATION.md` is reported missing.

- [ ] **Step 2: Write the exact maintenance and privacy boundaries**

`AUTHENTICATION.md` must include:

1. Phase 1 status and explicit non-production warning.
2. Component responsibility table matching the spec.
3. State transition table for disabled, signed out, restoring, signing in,
   signed in, reauthentication, failed, and signing out.
4. Exact mock invocation: `YTDP_AUTH_MODE=mock`.
5. Exact disabled invocation: unset the variable or use any value other than
   lowercase `mock`.
6. Keychain service, account key, accessibility class, single-envelope rule,
   and test namespace cleanup.
7. Diagnostic event inventory and prohibited payloads.
8. Steps for adding a future provider, ending with the requirement for a new
   approved spec and plan.
9. Troubleshooting for missing UI, expired mock credentials, unavailable
   Keychain, and clearing only the mock authentication record.

Update the other five documents so they explicitly distinguish "implemented
local mock skeleton" from "proposed real account/entitlement system". Add Apple
as a future identity provider in `ENTITLEMENT_ARCHITECTURE.md`, but do not mark
Apple, Google, backend, billing, or entitlement delivery as implemented.

- [ ] **Step 3: Run the full strict Swift suite**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: every Swift test passes with zero failures and zero warnings. If the
suite times out, rerun the exact last test filter before attributing the timeout
to the change.

- [ ] **Step 4: Run release, privacy, and repository verification**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
swift build --package-path swift-2.0 --configuration release \
  --triple arm64-apple-macosx13.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

git diff --check

if rg -n 'accounts\.google\.com|appleid\.apple\.com|oauth2|ECPay|HashKey|HashIV|URLSession|ASWebAuthenticationSession' \
  swift-2.0/Sources/YTDownloaderPro2/Authentication; then
  printf '%s\n' 'unexpected real-provider or network surface found'
  exit 1
fi
```

Expected: the arm64 macOS 13 release build succeeds, the diff has no whitespace
errors, and the authentication folder contains no real-provider, network, or
payment surface.

Perform two manual smoke checks from the debug executable:

1. Launch with `YTDP_AUTH_MODE` unset. Confirm the sidebar and Settings contain
   no account controls, then analyze and start one ordinary free download.
2. Launch with `YTDP_AUTH_MODE=mock`. Exercise Google and Apple mock sign-in,
   restart restoration, and sign-out while another download remains active.
   Confirm sign-out preserves jobs, settings, history, and media. Cancellation,
   expired credentials, malformed credentials, and injected errors are verified
   by the focused deterministic tests rather than hidden UI controls.

- [ ] **Step 5: Commit documentation and final evidence**

```bash
git add docs/swift-2.0/AUTHENTICATION.md \
  docs/swift-2.0/ARCHITECTURE.md \
  docs/swift-2.0/DEVELOPMENT.md \
  ENTITLEMENT_ARCHITECTURE.md \
  PRIVACY_DATA_MAP.md \
  PRIVACY_THREAT_MODEL.md
git commit -m "docs(swift): document authentication skeleton"
```

After the commit, rerun `git status --short --branch` and `git log --oneline
origin/main..HEAD`. The implementation branch must contain only the planned
authentication and documentation commits, with no app bundles, archives,
credentials, screenshots, or unrelated root-worktree files.
