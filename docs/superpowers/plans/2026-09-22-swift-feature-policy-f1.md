# Swift Feature Policy F1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure local Free/Pro feature-policy subsystem and development-only enforcement for quality, multi-URL input, and playlist expansion while preserving the normal public 2.0.1 behavior.

**Architecture:** Immutable entitlement snapshots derive a pure `FeaturePolicy`; a `FeaturePolicyContext` adds the transitional public-compatibility mode. `DownloadStore` owns command admission, while media-option presentation uses the same context to choose a Free-safe default. Exact environment values enable synthetic Free or Pro enforcement without any account, network, token, or payment service.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, Foundation, XCTest, Swift Package Manager strict concurrency

**Spec:** `docs/superpowers/specs/2026-09-22-swift-feature-policy-f1-design.md`

## Global Constraints

- Target macOS 13 or later and keep Swift strict-concurrency warnings as errors.
- Keep Windows Python 1.8.x unchanged.
- Do not contact Google, Apple, ECPay, a backend, analytics, email, support, or any external service.
- Do not parse, verify, refresh, or persist a production entitlement token.
- Do not activate Free limits in a normal public 2.0.1 launch.
- Missing, empty, whitespace-padded, differently cased, or unknown feature-policy environment values must not enable mock enforcement.
- `YTDP_FEATURE_POLICY_MODE=mock-free` and `YTDP_FEATURE_POLICY_MODE=mock-pro` are the only enforcement gates in F1.
- Keep authentication mock state independent from entitlement policy; a mock signed-in Pro label never grants features.
- Never pass media URLs, titles, cookies, paths, thumbnails, history, or account identity into policy decisions or diagnostics.
- Preserve local history, manual retry, safety recovery, and completed media for Free users.
- Use TDD for every task: observe the focused regression test fail before adding the production behavior.
- Commit only the files listed by the current task after its focused tests pass.

## File Structure

Create focused files under `swift-2.0/Sources/YTDownloaderPro2/Entitlements/`:

- `FeatureID.swift`: stable capability identifiers and known-identifier set.
- `EntitlementSnapshot.swift`: trusted local snapshot value, plan, video-height policy, and synthetic fixtures.
- `FeaturePolicy.swift`: pure decisions, denials, Free fallback, and policy context.
- `FeaturePolicyEnvironment.swift`: exact development-mode resolution with sanitized fallback metadata.
- `FeaturePolicyPresentation.swift`: localization-key mapping for structured denials.

Create focused tests:

- `FeaturePolicyTests.swift`: product matrix and malformed-input behavior.
- `FeaturePolicyEnvironmentTests.swift`: exact environment resolution and fixture privacy.
- Extend `OptionsPresentationTests.swift`: best eligible Free default and unrestricted compatibility behavior.
- Extend `DownloadStoreTests.swift`: Store-boundary admission and no-partial-job guarantees.
- Extend `LocalizationTests.swift`: three-locale denial copy coverage.

Modify integration files only where the policy is consumed:

- `MediaOptionsSheet.swift`: inject policy context and choose an eligible default.
- `DownloadStore.swift`: inject context, publish a denial, and enforce Store commands.
- `DownloadCenterView.swift`: pass context to sheets and present localized denial alerts.
- `YTDownloaderPro2App.swift`: resolve the exact environment once for the live Store.
- `Localization.swift` and `Localizable.xcstrings`: stable localization keys and three translations.
- `ARCHITECTURE.md`, `DEVELOPMENT.md`, and `ENTITLEMENT_ARCHITECTURE.md`: document the implemented local boundary.

## Review Focus

- A normal launch with no environment variable must keep current batch, playlist, and highest-quality behavior.
- Unknown, padded, or differently cased environment values must not accidentally enable Free or Pro enforcement.
- A Free video format with missing height must be denied rather than guessed safe; MP3 must remain allowed.
- A denied batch or playlist must create no placeholder or child jobs and must not start metadata analysis beyond what is necessary to discover a single playlist.
- Authentication mock `planPreview == .pro` must have no effect on `FeaturePolicyContext`.

## Execution Preflight

Before Task 1, confirm the implementation worktree is clean except for this
committed plan and run the existing strict suite once:

```bash
git status --short --branch
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: the branch is clean and the existing suite passes. If the baseline
fails, record the failure and diagnose it before writing the first F1 test.

---

### Task 1: Stable Feature And Snapshot Values

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeatureID.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementSnapshot.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/FeaturePolicyTests.swift`

**Interfaces:**
- Produces: `FeatureID`, `EntitlementPlan`, `EntitlementSubscriptionState`, `VideoHeightPolicy`, and `EntitlementSnapshot`.
- Produces: `EntitlementSnapshot.syntheticFree` and `.syntheticPro` as in-memory fixtures.
- Consumes: Foundation Codable, Hashable, and Sendable only.

- [ ] **Step 1: Add failing tests for stable identifiers and synthetic snapshots**

Create `FeaturePolicyTests.swift` with the first contract tests:

```swift
import XCTest
@testable import YTDownloaderPro2

final class FeaturePolicyTests: XCTestCase {
    func testFeatureIdentifiersUseStableSerializedValues() throws {
        XCTAssertEqual(FeatureID.downloadSingle.rawValue, "download.single")
        XCTAssertEqual(FeatureID.videoHD.rawValue, "video.hd")
        XCTAssertEqual(FeatureID.queueBatch.rawValue, "queue.batch")
        XCTAssertEqual(FeatureID.supportPriority.rawValue, "support.priority")
        XCTAssertEqual(
            try JSONDecoder().decode(FeatureID.self, from: Data("\"future.capability\"".utf8)),
            FeatureID(rawValue: "future.capability")
        )
    }

    func testSyntheticFreeSnapshotContainsOnlyApprovedFreeCapabilities() {
        let snapshot = EntitlementSnapshot.syntheticFree

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.plan, .free)
        XCTAssertEqual(snapshot.videoHeightPolicy, .limited(720))
        XCTAssertTrue(snapshot.features.contains(.downloadSingle))
        XCTAssertTrue(snapshot.features.contains(.audioMP3))
        XCTAssertTrue(snapshot.features.contains(.subtitleBasic))
        XCTAssertTrue(snapshot.features.contains(.historyLocal))
        XCTAssertFalse(snapshot.features.contains(.queueBatch))
        XCTAssertFalse(snapshot.features.contains(.playlistExpand))
        XCTAssertFalse(snapshot.features.contains(.videoHD))
    }

    func testSyntheticProSnapshotContainsEveryKnownCapability() {
        XCTAssertEqual(EntitlementSnapshot.syntheticPro.plan, .pro)
        XCTAssertEqual(EntitlementSnapshot.syntheticPro.videoHeightPolicy, .unlimited)
        XCTAssertEqual(EntitlementSnapshot.syntheticPro.features, FeatureID.known)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the types are missing**

Run:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter FeaturePolicyTests \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: compilation fails because `FeatureID` and `EntitlementSnapshot` do not exist.

- [ ] **Step 3: Implement stable identifiers and immutable snapshots**

Implement `FeatureID` as a String-backed struct so unknown future identifiers survive decoding but do not enter `known`:

```swift
import Foundation

struct FeatureID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let downloadSingle = Self(rawValue: "download.single")
    static let videoStandard = Self(rawValue: "video.standard")
    static let videoHD = Self(rawValue: "video.hd")
    static let videoUHD = Self(rawValue: "video.uhd")
    static let audioMP3 = Self(rawValue: "audio.mp3")
    static let queueBatch = Self(rawValue: "queue.batch")
    static let playlistExpand = Self(rawValue: "playlist.expand")
    static let subtitleBasic = Self(rawValue: "subtitle.basic")
    static let subtitleAdvanced = Self(rawValue: "subtitle.advanced")
    static let formatPresets = Self(rawValue: "format.presets")
    static let recoveryManual = Self(rawValue: "recovery.manual")
    static let recoveryFull = Self(rawValue: "recovery.full")
    static let historyLocal = Self(rawValue: "history.local")
    static let historySync = Self(rawValue: "history.sync")
    static let supportStandard = Self(rawValue: "support.standard")
    static let supportPriority = Self(rawValue: "support.priority")

    static let known: Set<Self> = [
        .downloadSingle, .videoStandard, .videoHD, .videoUHD, .audioMP3,
        .queueBatch, .playlistExpand, .subtitleBasic, .subtitleAdvanced,
        .formatPresets, .recoveryManual, .recoveryFull, .historyLocal,
        .historySync, .supportStandard, .supportPriority
    ]
}
```

Implement snapshot values with exact local fixture contents:

```swift
import Foundation

enum EntitlementPlan: String, Codable, Equatable, Sendable {
    case free
    case pro
}

enum EntitlementSubscriptionState: String, Codable, Equatable, Sendable {
    case none
    case active
}

enum VideoHeightPolicy: Codable, Equatable, Sendable {
    case limited(Int)
    case unlimited
}

struct EntitlementSnapshot: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let plan: EntitlementPlan
    let features: Set<FeatureID>
    let videoHeightPolicy: VideoHeightPolicy
    let subscriptionState: EntitlementSubscriptionState

    static let syntheticFree = EntitlementSnapshot(
        schemaVersion: supportedSchemaVersion,
        plan: .free,
        features: [
            .downloadSingle, .videoStandard, .audioMP3, .subtitleBasic,
            .recoveryManual, .historyLocal, .supportStandard
        ],
        videoHeightPolicy: .limited(720),
        subscriptionState: .none
    )

    static let syntheticPro = EntitlementSnapshot(
        schemaVersion: supportedSchemaVersion,
        plan: .pro,
        features: FeatureID.known,
        videoHeightPolicy: .unlimited,
        subscriptionState: .active
    )
}
```

Dates and account identifiers are deliberately absent from synthetic fixtures.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run the Task 1 command again. Expected: `FeaturePolicyTests` passes.

- [ ] **Step 5: Commit the value contracts**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeatureID.swift \
  swift-2.0/Sources/YTDownloaderPro2/Entitlements/EntitlementSnapshot.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/FeaturePolicyTests.swift
git commit -m "feat(swift): define feature entitlement values"
```

### Task 2: Pure Feature Decisions And Free Fallback

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeaturePolicy.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/FeaturePolicyTests.swift`

**Interfaces:**
- Consumes: `EntitlementSnapshot` and `FeatureID` from Task 1.
- Produces: `FeaturePolicy`, `FeaturePolicyContext`, `FeatureDecision`, `FeatureDenial`, `FeatureDenialReason`, and `FeaturePolicyFallbackReason`.
- Produces exact query signatures from the spec: feature, video, URL count, playlist, and subtitle decisions.

- [ ] **Step 1: Add failing product-matrix and malformed-input tests**

Add tests covering every approved capability and the five high-risk boundaries:

```swift
func testFreeVideoBoundaryAllows720AndDeniesUnknownOrHigherVideo() {
    let policy = FeaturePolicy(snapshot: .syntheticFree)

    XCTAssertEqual(policy.videoDecision(height: 720, isAudioOnly: false, isSourceQuality: false), .allowed)
    XCTAssertEqual(policy.videoDecision(height: 721, isAudioOnly: false, isSourceQuality: false).denial?.reason, .videoHeightRequiresPro)
    XCTAssertEqual(policy.videoDecision(height: nil, isAudioOnly: false, isSourceQuality: false).denial?.reason, .unknownVideoHeight)
    XCTAssertEqual(policy.videoDecision(height: nil, isAudioOnly: true, isSourceQuality: false), .allowed)
}

func testFreeAndProURLPlaylistSubtitleRetryAndHistoryMatrix() {
    let free = FeaturePolicy(snapshot: .syntheticFree)
    let pro = FeaturePolicy(snapshot: .syntheticPro)

    XCTAssertEqual(free.urlSubmissionDecision(count: 1), .allowed)
    XCTAssertEqual(free.urlSubmissionDecision(count: 2).denial?.requiredFeature, .queueBatch)
    XCTAssertEqual(free.urlSubmissionDecision(count: 0).denial?.reason, .invalidRequest)
    XCTAssertEqual(free.playlistExpansionDecision().denial?.requiredFeature, .playlistExpand)
    XCTAssertEqual(pro.urlSubmissionDecision(count: 10), .allowed)
    XCTAssertEqual(pro.playlistExpansionDecision(), .allowed)
    XCTAssertEqual(free.subtitleDecision(languageCount: 1, usesAdvancedMode: false), .allowed)
    XCTAssertEqual(free.subtitleDecision(languageCount: 2, usesAdvancedMode: false).denial?.requiredFeature, .subtitleAdvanced)
    XCTAssertEqual(free.decision(for: .recoveryManual), .allowed)
    XCTAssertEqual(free.decision(for: .recoveryFull).denial?.requiredFeature, .recoveryFull)
    XCTAssertEqual(free.decision(for: .historyLocal), .allowed)
    XCTAssertEqual(free.decision(for: .historySync).denial?.requiredFeature, .historySync)
}

func testUnsupportedSchemaAndUnknownFeaturesFallBackToFree() {
    let snapshot = EntitlementSnapshot(
        schemaVersion: 99,
        plan: .pro,
        features: FeatureID.known.union([FeatureID(rawValue: "future.capability")]),
        videoHeightPolicy: .unlimited,
        subscriptionState: .active
    )
    let policy = FeaturePolicy(snapshot: snapshot)

    XCTAssertEqual(policy.fallbackReason, .unsupportedSchema)
    XCTAssertEqual(policy.videoDecision(height: 1080, isAudioOnly: false, isSourceQuality: false).denial?.requiredFeature, .videoHD)
    XCTAssertFalse(policy.grantedFeatures.contains(FeatureID(rawValue: "future.capability")))
}

func testPublicCompatibilityAllowsWithoutPretendingToBePro() {
    let context = FeaturePolicyContext.publicCompatibility

    XCTAssertFalse(context.isEnforced)
    XCTAssertNil(context.plan)
    XCTAssertEqual(context.urlSubmissionDecision(count: 5), .allowed)
    XCTAssertEqual(context.videoDecision(height: nil, isAudioOnly: false, isSourceQuality: true), .allowed)
}
```

- [ ] **Step 2: Run the focused tests and verify decision types are missing**

Run the Task 1 focused command. Expected: compilation fails on the policy types.

- [ ] **Step 3: Implement deterministic policy and context**

Use structured values, not strings or UI copy:

```swift
enum FeatureDecision: Equatable, Sendable {
    case allowed
    case denied(FeatureDenial)

    var denial: FeatureDenial? {
        guard case let .denied(value) = self else { return nil }
        return value
    }
}

struct FeatureDenial: Equatable, Sendable, Identifiable {
    let requiredFeature: FeatureID?
    let reason: FeatureDenialReason
    let canChooseFreeAlternative: Bool
    var id: String { "\(reason.rawValue):\(requiredFeature?.rawValue ?? "none")" }
}

enum FeatureDenialReason: String, Equatable, Sendable {
    case videoHeightRequiresPro
    case sourceQualityRequiresPro
    case unknownVideoHeight
    case batchRequiresPro
    case playlistRequiresPro
    case advancedSubtitlesRequirePro
    case featureUnavailable
    case invalidRequest
}
```

`FeaturePolicy(snapshot:)` must replace unsupported schemas with
`.syntheticFree`, intersect features with `FeatureID.known`, and record
`.unsupportedSchema`. `FeaturePolicyContext.publicCompatibility` returns
`.allowed` from every query while exposing `isEnforced == false` and
`plan == nil`. `.enforced(policy)` delegates to the pure policy.

Use these stored values and derivation rules:

```swift
enum FeaturePolicyFallbackReason: Equatable, Sendable {
    case unsupportedSchema
}

struct FeaturePolicy: Equatable, Sendable {
    let plan: EntitlementPlan
    let grantedFeatures: Set<FeatureID>
    let videoHeightPolicy: VideoHeightPolicy
    let fallbackReason: FeaturePolicyFallbackReason?

    init(snapshot: EntitlementSnapshot) {
        let accepted: EntitlementSnapshot
        if snapshot.schemaVersion == EntitlementSnapshot.supportedSchemaVersion {
            accepted = snapshot
            fallbackReason = nil
        } else {
            accepted = .syntheticFree
            fallbackReason = .unsupportedSchema
        }
        plan = accepted.plan
        grantedFeatures = accepted.features.intersection(FeatureID.known)
        videoHeightPolicy = accepted.videoHeightPolicy
    }

    func decision(for feature: FeatureID) -> FeatureDecision {
        guard grantedFeatures.contains(feature) else {
            return .denied(FeatureDenial(
                requiredFeature: feature,
                reason: denialReason(for: feature),
                canChooseFreeAlternative: [.videoHD, .videoUHD, .queueBatch, .subtitleAdvanced].contains(feature)
            ))
        }
        return .allowed
    }

    func urlSubmissionDecision(count: Int) -> FeatureDecision {
        guard count > 0 else { return invalidRequest() }
        return decision(for: count == 1 ? .downloadSingle : .queueBatch)
    }

    func playlistExpansionDecision() -> FeatureDecision {
        decision(for: .playlistExpand)
    }

    func subtitleDecision(languageCount: Int, usesAdvancedMode: Bool) -> FeatureDecision {
        guard languageCount >= 0 else { return invalidRequest() }
        return decision(for: languageCount <= 1 && !usesAdvancedMode ? .subtitleBasic : .subtitleAdvanced)
    }
}
```

Add private helpers that return `.invalidRequest`, `.unknownVideoHeight`, and
the feature-specific denial reasons without localization strings. Implement
`FeaturePolicyContext` as an enum with forwarding methods matching every public
`FeaturePolicy` query. Each forwarding method returns `.allowed` in
`.publicCompatibility` and delegates in `.enforced`.

Video decision order is exact:

1. Audio-only returns the `audio.mp3` feature decision.
2. Non-positive heights are invalid.
3. Source quality or height at least 2160 requires `video.uhd`.
4. A known height above 720 requires `video.hd`.
5. Unknown video height under a limited policy returns `.unknownVideoHeight`.
6. A known height above any lower configured limit requires `video.hd`.
7. Unknown video height under an unlimited policy requires `video.hd`.
8. A known eligible height requires `video.standard`.

- [ ] **Step 4: Run the focused policy tests and verify they pass**

Run the Task 1 focused command. Expected: all `FeaturePolicyTests` pass.

- [ ] **Step 5: Commit pure policy behavior**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeaturePolicy.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/FeaturePolicyTests.swift
git commit -m "feat(swift): add pure Free and Pro policy decisions"
```

### Task 3: Exact Development Environment Resolution

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeaturePolicyEnvironment.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/FeaturePolicyEnvironmentTests.swift`

**Interfaces:**
- Consumes: `FeaturePolicyContext` and synthetic snapshots.
- Produces: `FeaturePolicyEnvironmentResolution.resolve(from:)` with `context`, `mode`, and a Boolean sanitized-fallback indicator.
- Does not consume `AccountSessionStore`, `MockPlanPreview`, or process-global state in tests.

- [ ] **Step 1: Add failing exact-value and privacy tests**

```swift
import XCTest
@testable import YTDownloaderPro2

final class FeaturePolicyEnvironmentTests: XCTestCase {
    func testOnlyExactMockValuesEnableEnforcement() {
        XCTAssertEqual(FeaturePolicyEnvironmentResolution.resolve(from: [:]).mode, .publicCompatibility)
        XCTAssertEqual(FeaturePolicyEnvironmentResolution.resolve(from: ["YTDP_FEATURE_POLICY_MODE": "mock-free"]).mode, .mockFree)
        XCTAssertEqual(FeaturePolicyEnvironmentResolution.resolve(from: ["YTDP_FEATURE_POLICY_MODE": "mock-pro"]).mode, .mockPro)

        for raw in ["", " mock-free", "mock-free ", "MOCK-FREE", "free", "pro", "unexpected"] {
            let resolution = FeaturePolicyEnvironmentResolution.resolve(
                from: ["YTDP_FEATURE_POLICY_MODE": raw]
            )
            XCTAssertEqual(resolution.mode, .publicCompatibility, raw)
            XCTAssertFalse(resolution.context.isEnforced, raw)
        }
    }

    func testUnknownValueReportsOnlySanitizedFallbackMetadata() {
        let resolution = FeaturePolicyEnvironmentResolution.resolve(
            from: ["YTDP_FEATURE_POLICY_MODE": "secret-looking-value"]
        )

        XCTAssertTrue(resolution.usedUnsupportedValueFallback)
        XCTAssertEqual(resolution.diagnosticDetail, "Unsupported feature-policy mode; using public compatibility.")
        XCTAssertFalse(resolution.diagnosticDetail?.contains("secret-looking-value") == true)
    }

    func testAuthenticationEnvironmentCannotChangeFeaturePolicy() {
        let accountPreview = MockPlanPreview.pro
        let policy = FeaturePolicyEnvironmentResolution.resolve(from: [:]).context

        XCTAssertEqual(accountPreview, .pro)
        XCTAssertFalse(policy.isEnforced)
        XCTAssertNil(policy.plan)
    }
}
```

- [ ] **Step 2: Run the environment tests and verify they fail**

Run:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter FeaturePolicyEnvironmentTests \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: compilation fails because environment resolution does not exist.

- [ ] **Step 3: Implement exact fail-compatible development resolution**

```swift
enum FeaturePolicyEnvironmentMode: String, Equatable, Sendable {
    case publicCompatibility
    case mockFree
    case mockPro
}

struct FeaturePolicyEnvironmentResolution: Equatable, Sendable {
    let mode: FeaturePolicyEnvironmentMode
    let context: FeaturePolicyContext
    let usedUnsupportedValueFallback: Bool

    var diagnosticDetail: String? {
        usedUnsupportedValueFallback
            ? "Unsupported feature-policy mode; using public compatibility."
            : nil
    }

    static func resolve(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        switch environment["YTDP_FEATURE_POLICY_MODE"] {
        case "mock-free":
            return .init(mode: .mockFree, context: .enforced(.init(snapshot: .syntheticFree)), usedUnsupportedValueFallback: false)
        case "mock-pro":
            return .init(mode: .mockPro, context: .enforced(.init(snapshot: .syntheticPro)), usedUnsupportedValueFallback: false)
        case nil:
            return .init(mode: .publicCompatibility, context: .publicCompatibility, usedUnsupportedValueFallback: false)
        default:
            return .init(mode: .publicCompatibility, context: .publicCompatibility, usedUnsupportedValueFallback: true)
        }
    }
}
```

- [ ] **Step 4: Run policy and environment tests together**

Run:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter 'FeaturePolicyTests|FeaturePolicyEnvironmentTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: both suites pass with no warning.

- [ ] **Step 5: Commit the development gate**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeaturePolicyEnvironment.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/FeaturePolicyEnvironmentTests.swift
git commit -m "feat(swift): gate synthetic feature policies"
```

### Task 4: Free-Safe Format Defaults And Localized Denial Presentation

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeaturePolicyPresentation.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/MediaOptionsSheet.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/OptionsPresentationTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `FeaturePolicyContext.videoDecision(...)`.
- Produces: `FeaturePolicyDenialPresentation` with title and message localization keys.
- Changes: `MediaOptionsPresentation.init(analysis:defaults:featurePolicy:)`, defaulting `featurePolicy` to `.publicCompatibility` for source compatibility.
- Produces: `MediaOptionsPresentation.decisionForSelectedOptions(in:)` for the Store and sheet to use consistently.

- [ ] **Step 1: Add failing format-default and localization tests**

Add these focused expectations:

```swift
func testMockFreeDefaultsToHighestQuickTimeCompatibleVideoAtOrBelow720p() {
    let analysis = videoAnalysis(videoFormats: [
        format(id: "2160", label: "2160p", videoCodec: "avc1", container: "mp4", height: 2160),
        format(id: "1080", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080),
        format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
    ], audioFormats: [])

    let model = MediaOptionsPresentation(
        analysis: analysis,
        defaults: .defaults,
        featurePolicy: .enforced(.init(snapshot: .syntheticFree))
    )

    XCTAssertEqual(model.videoChoices.map(\.id), ["2160", "1080", "720"])
    XCTAssertEqual(model.selectedVideoID, "720")
}

func testPublicCompatibilityStillDefaultsToHighestCompatibleVideo() {
    let analysis = videoAnalysis(videoFormats: [
        format(id: "2160", label: "2160p", videoCodec: "avc1", container: "mp4", height: 2160),
        format(id: "720", label: "720p", videoCodec: "avc1", container: "mp4", height: 720)
    ], audioFormats: [])

    XCTAssertEqual(
        MediaOptionsPresentation(analysis: analysis, defaults: .defaults).selectedVideoID,
        "2160"
    )
}
```

Extend the existing private `format(...)` helper in
`OptionsPresentationTests.swift` so the tests can preserve analyzed height:

```swift
private func format(
    id: String,
    label: String,
    videoCodec: String? = nil,
    audioCodec: String? = nil,
    container: String? = nil,
    height: Int? = nil
) -> MediaFormat {
    MediaFormat(
        id: id,
        label: label,
        codec: nil,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        container: container,
        width: nil,
        height: height,
        resolution: nil,
        framesPerSecond: nil,
        bitrate: nil,
        language: nil,
        estimatedFileSize: nil
    )
}
```

Extend `LocalizationTests` to assert each new key returns a non-empty, non-key
value for `en`, `ja`, and `zh-Hant`.

- [ ] **Step 2: Run presentation and localization tests and verify failure**

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter 'OptionsPresentationTests|LocalizationTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: failure because policy injection and denial localization keys are absent.

- [ ] **Step 3: Add policy-aware default selection without hiding formats**

Keep `videoChoices` unchanged for inspection. Build `eligibleVideoFormats` from
QuickTime-compatible choices whose policy decision is allowed, and use it only
for the default when policy is enforced:

```swift
let compatibleVideoFormats = defaults.outputKind == .mp4
    ? analysis.videoFormats.filter(QuickTimeMP4Compatibility.supportsVideo)
    : analysis.videoFormats
let defaultVideoFormats = featurePolicy.isEnforced
    ? compatibleVideoFormats.filter {
        featurePolicy.videoDecision(
            height: $0.height,
            isAudioOnly: defaults.outputKind == .mp3,
            isSourceQuality: $0.height.map { $0 >= 2160 } ?? false
        ) == .allowed
    }
    : compatibleVideoFormats
selectedVideoID = Self.selectedID(for: defaults.videoQuality, in: defaultVideoFormats)
    ?? defaultVideoFormats.first?.id
```

`decisionForSelectedOptions(in:)` must return allowed for MP3 and otherwise use
the selected structured format. A missing video height under enforced Free mode
returns `.unknownVideoHeight` through the policy.

- [ ] **Step 4: Add denial localization mapping and three translations**

Add stable keys for the development title, height, unknown height, batch,
playlist, advanced subtitles, unavailable feature, and invalid request. Map
`FeatureDenialReason` exhaustively in `FeaturePolicyDenialPresentation`.

Copy must say the capability is part of the planned Pro policy and that this is
a development test mode; it must not advertise a price, imply a purchase is
available, or provide a checkout action.

- [ ] **Step 5: Run focused presentation and localization tests**

Run the Task 4 command. Expected: all focused tests pass.

- [ ] **Step 6: Commit format and presentation behavior**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements/FeaturePolicyPresentation.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views/MediaOptionsSheet.swift \
  swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift \
  swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings \
  swift-2.0/Tests/YTDownloaderPro2Tests/OptionsPresentationTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift
git commit -m "feat(swift): present development feature denials"
```

### Task 5: Enforce Batch, Playlist, And Quality At Store Boundaries

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`

**Interfaces:**
- Consumes: `FeaturePolicyContext` and `MediaOptionsPresentation.decisionForSelectedOptions(in:)`.
- Adds: `DownloadStore.featurePolicyContext` and published `featurePolicyDenial`.
- Adds: `DownloadStore.dismissFeaturePolicyDenial()`.
- Changes: `DownloadStore.init(..., featurePolicyContext: .publicCompatibility)` and `DownloadStore.live(..., featurePolicyResolution:)`.

- [ ] **Step 1: Add failing Store admission tests**

Extend `StoreFixture` with a `featurePolicyContext` argument defaulting to public
compatibility and inject it into `DownloadStore`.

Add tests proving denial happens before side effects:

```swift
func testMockFreeRejectsBatchBeforeCreatingJobsOrAnalyzing() async throws {
    let recorder = AnalysisRecorder(result: .video(.fixture()))
    let fixture = try StoreFixture(
        analysis: { try await recorder.analyze(url: $0, options: $1) },
        featurePolicyContext: .enforced(.init(snapshot: .syntheticFree))
    )
    defer { fixture.cleanUp() }

    let result = await fixture.store.submitURLInput("https://example.com/a\nhttps://example.com/b")

    XCTAssertEqual(result.acceptedCount, 0)
    XCTAssertTrue(fixture.store.jobs.isEmpty)
    XCTAssertEqual(await recorder.recordedURLs(), [])
    XCTAssertEqual(fixture.store.featurePolicyDenial?.reason, .batchRequiresPro)
}

func testMockFreeRejectsSinglePlaylistBeforePublishingSheetOrChildren() async throws {
    let fixture = try StoreFixture(
        analysis: .playlist(.fixture(entryCount: 2)),
        featurePolicyContext: .enforced(.init(snapshot: .syntheticFree))
    )
    defer { fixture.cleanUp() }

    await fixture.store.submitURLInput("https://example.com/playlist")

    XCTAssertEqual(fixture.store.analysisState, .idle)
    XCTAssertTrue(fixture.store.jobs.isEmpty)
    XCTAssertEqual(fixture.store.featurePolicyDenial?.reason, .playlistRequiresPro)
}

func testMockFreeRejectsHighVideoBeforeCreatingOrStartingJob() async throws {
    let fixture = try StoreFixture(
        analysis: .video(.fixture()),
        featurePolicyContext: .enforced(.init(snapshot: .syntheticFree))
    )
    defer { fixture.cleanUp() }
    await fixture.store.analyzeURL("https://example.com/video")
    var options = DownloadOptions.defaults
    options.selectVideoFormat(MediaFormat(id: "137", label: "1080p", videoCodec: "avc1", container: "mp4", height: 1080))

    await fixture.store.addVideo(options: options)

    XCTAssertTrue(fixture.store.jobs.isEmpty)
    XCTAssertEqual(await fixture.runner.startedIDs(), [])
    XCTAssertEqual(fixture.store.featurePolicyDenial?.reason, .videoHeightRequiresPro)
}
```

Also add:

- mock Free accepts one 720p video and MP3;
- mock Pro preserves batch and playlist flows;
- public compatibility preserves current multi-URL, playlist, and highest-format tests;
- a denied `addPlaylistEntries` creates no jobs;
- dismiss clears only the current denial.

- [ ] **Step 2: Run DownloadStore tests and verify the new tests fail**

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter DownloadStoreTests \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: compilation or assertions fail because the Store has no policy boundary.

- [ ] **Step 3: Inject the context and centralize denial publication**

Add these Store members:

```swift
@Published private(set) var featurePolicyDenial: FeatureDenial?
let featurePolicyContext: FeaturePolicyContext

private func deny(_ decision: FeatureDecision) -> Bool {
    guard case let .denied(denial) = decision else { return false }
    featurePolicyDenial = denial
    return true
}

func dismissFeaturePolicyDenial() {
    featurePolicyDenial = nil
}
```

Keep the initializer default `.publicCompatibility` so existing tests and
non-live construction retain current behavior.

- [ ] **Step 4: Enforce before each command side effect**

Apply checks in this order:

1. `submitURLInput`: after parsing/deduplication but before placeholders or
   analysis, check the accepted URL count. On denial return `acceptedCount: 0`
   while preserving rejected and duplicate counts.
2. `analyzeURL`: after successful metadata analysis but before publishing a
   playlist state, check playlist expansion. On denial set `.idle` and publish
   the denial.
3. `addVideo`: before constructing a job, check selected output with the policy.
4. `addPlaylistEntries`: before constructing child jobs, check playlist policy.
5. `adoptBatchPlaylist`: check again before replacing a placeholder so a direct
   or restored development fixture cannot bypass the command boundary.

Do not write policy denials into `DownloadFailure`; commercial decisions remain
separate from download and tool errors.

- [ ] **Step 5: Run DownloadStore plus policy tests**

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter 'FeaturePolicyTests|FeaturePolicyEnvironmentTests|DownloadStoreTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: all selected tests pass and no existing public-compatibility test changes behavior.

- [ ] **Step 6: Commit Store admission**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift
git commit -m "feat(swift): enforce mock feature policy in download store"
```

### Task 6: Wire Live Mode, Alert Presentation, Diagnostics, And Documentation

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift`
- Modify: `docs/swift-2.0/ARCHITECTURE.md`
- Modify: `docs/swift-2.0/DEVELOPMENT.md`
- Modify: `ENTITLEMENT_ARCHITECTURE.md`

**Interfaces:**
- Consumes: `FeaturePolicyEnvironmentResolution` once at live app construction.
- Consumes: `FeaturePolicyDenialPresentation` in the center view.
- Produces: one sanitized `feature-policy-environment` diagnostic only for an unsupported environment value.
- Preserves: all injected test/lifecycle initializers and disabled account defaults.

- [ ] **Step 1: Add failing live wiring, alert, and sanitized diagnostic tests**

Add tests that verify:

```swift
func testDefaultLivePolicyResolutionKeepsPublicCompatibility() {
    let resolution = FeaturePolicyEnvironmentResolution.resolve(from: [:])
    XCTAssertFalse(resolution.context.isEnforced)
}

func testPolicyDenialPresentationMapsEveryReason() {
    for reason in FeatureDenialReason.allCases {
        let denial = FeatureDenial(requiredFeature: nil, reason: reason, canChooseFreeAlternative: false)
        let presentation = FeaturePolicyDenialPresentation(denial: denial)
        XCTAssertFalse(presentation.titleKey.rawValue.isEmpty)
        XCTAssertFalse(presentation.messageKey.rawValue.isEmpty)
    }
}
```

Make `FeatureDenialReason` conform to `CaseIterable` for exhaustive presentation
coverage. Add a diagnostics test that writes the environment fallback event and
asserts the stored/exported text contains only the fixed sanitized sentence,
not the supplied raw value.

- [ ] **Step 2: Run the view and diagnostics tests and verify failure**

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter 'DownloadCenterViewTests|DiagnosticsLoggerTests|LocalizationTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: new wiring/presentation assertions fail before integration.

- [ ] **Step 3: Resolve the live policy once and record only sanitized fallback**

In `AppLifecycle` default initialization, resolve the environment once and pass
the result into `DownloadStore.live(featurePolicyResolution:)`. The Store uses
`resolution.context`; when `diagnosticDetail` is non-nil, it records:

```swift
DiagnosticEvent(
    stage: "feature-policy-environment",
    technicalDetail: resolution.diagnosticDetail
)
```

Never include the original environment value in arguments or detail.

- [ ] **Step 4: Pass policy to sheets and present a development-only alert**

Every `MediaOptionsSheet` created from analyzed media receives
`store.featurePolicyContext`. Add one alert bound to
`store.featurePolicyDenial`, using `FeaturePolicyDenialPresentation`, the
current app locale, and a single Close button that calls
`dismissFeaturePolicyDenial()`.

Do not add pricing, purchase, account, or external-link controls. Public
compatibility never produces a policy denial, so the normal release UI is
unchanged.

- [ ] **Step 5: Document exact launch commands and security boundary**

Add these development examples to `DEVELOPMENT.md`:

```bash
YTDP_FEATURE_POLICY_MODE=mock-free swift run --package-path swift-2.0 YTDownloaderPro2
YTDP_FEATURE_POLICY_MODE=mock-pro swift run --package-path swift-2.0 YTDownloaderPro2
```

State explicitly that they are synthetic policy fixtures, not account login,
purchase simulation, token verification, or proof of entitlement. Update
`ARCHITECTURE.md` with the `Entitlements/` ownership and public-compatibility
default. Cross-link the F1 spec from `ENTITLEMENT_ARCHITECTURE.md` without
changing its production gates.

- [ ] **Step 6: Run all focused tests**

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter 'FeaturePolicyTests|FeaturePolicyEnvironmentTests|OptionsPresentationTests|DownloadStoreTests|DownloadCenterViewTests|DiagnosticsLoggerTests|LocalizationTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: all focused tests pass.

- [ ] **Step 7: Run the complete strict Swift suite**

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: the complete suite passes with no new skip and no warning.

- [ ] **Step 8: Verify public compatibility with a release build**

```bash
env -u YTDP_FEATURE_POLICY_MODE \
  CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift build --package-path swift-2.0 --configuration release \
  --triple arm64-apple-macosx13.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: release build succeeds with public compatibility as the default. This
step does not sign, notarize, publish, or alter the 2.0.1 release candidate.

- [ ] **Step 9: Commit integration and documentation**

```bash
git add swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift \
  swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift \
  swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCenterViewTests.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift \
  docs/swift-2.0/ARCHITECTURE.md docs/swift-2.0/DEVELOPMENT.md \
  ENTITLEMENT_ARCHITECTURE.md
git commit -m "docs(swift): integrate local feature policy workflow"
```

## Final Review Checklist

- [ ] Inspect `git status --short` and confirm no unrelated root-worktree files are staged.
- [ ] Inspect `git diff HEAD~6..HEAD --check` for whitespace errors.
- [ ] Confirm only exact mock environment values enforce policy.
- [ ] Confirm a normal launch retains the existing full 2.0.1 feature behavior.
- [ ] Confirm no production endpoint, provider identifier, signing key, payment secret, email address, media URL, or output path was added to fixtures.
- [ ] Confirm denied batch/playlist/quality commands create no partial jobs.
- [ ] Confirm English, Japanese, and Traditional Chinese denial strings resolve.
- [ ] Confirm authentication mock Pro labels have no policy effect.
- [ ] Record focused-suite, full-suite, and release-build results in the final engineering report.
- [ ] Do not merge, push, tag, publish, sign, notarize, email, submit provider forms, or change repository visibility without a separate explicit request.
