# Swift Free And Test Pro Product Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing local feature-policy matrix into a public Free product capped at 720p and an internal-only Test Pro experience, without adding accounts, payment, a backend, or public release behavior.

**Architecture:** A main-actor `PlanController` derives one enforced `FeaturePolicyContext` from a build-gated plan provider. `DownloadStore` and `DownloadRunner` enforce immutable policy snapshots, while pure presentation types describe allowed and locked formats. Public and internal-test artifacts are compiled and verified as separate channels.

**Tech Stack:** Swift 5.9, SwiftUI, Combine, Foundation, XCTest, Swift Package Manager, Bash, Python bundle-verifier tests

**Spec:** `docs/superpowers/specs/2026-09-22-swift-free-pro-product-experience-design.md`

## Global Constraints

- Target macOS 13 or later and compile Swift with strict concurrency and warnings as errors.
- A public build starts Free, enforces supported video through 720p, and never reads an internal Test Pro preference.
- An internal-test build starts Free and may persist only exact `free` or `test-pro` synthetic state.
- Public UI and presentation-only plan mutation APIs do not compile unless `YTDP_INTERNAL_TEST` is defined.
- Keep authentication and plan state independent; no account presentation grants access.
- Add no real Google, Apple, OAuth, backend, token, ECPay, payment, analytics, email, cloud sync, or external navigation behavior.
- Do not change the Windows Python product line.
- No policy object or diagnostic may retain a media URL, title, path, cookie, format ID, thumbnail, account identity, or helper output.
- Free MP3 remains available. Unknown/source-class video height is not Free-safe.
- A Runner policy denial happens before security-scope access, output reservation, partial creation, temporary-file creation, or helper launch.
- Downgrading never terminates an already downloading or merging process and never deletes media, partials, history, thumbnails, settings, or diagnostics.
- Use TDD for every production change: observe the focused test fail for the intended reason before adding implementation.
- Commit only the current task after its focused and full strict suites pass.
- Do not tag, push, publish, notarize, change repository visibility, or perform any external-account action under this plan.

## File Structure

Plan and build-channel ownership lives under `swift-2.0/Sources/YTDownloaderPro2/Entitlements/`:

- `AppPlan.swift`: build channel, local plan values, and pure plan-to-policy mapping.
- `PlanProvider.swift`: public provider, exact internal preference store, and internal provider.
- `PlanController.swift`: main-actor observable state and internal-only mutation boundary.
- Existing `FeaturePolicy.swift`: remains the pure capability decision engine.

Execution ownership remains in existing download modules:

- `DownloadStore.swift`: current-policy admission, recovery, transition reconciliation, and restricted state.
- `DownloadRunner.swift`: final immutable policy check before any side effect.
- `DownloadJob.swift`: sanitized persisted access requirement.

Presentation ownership remains focused:

- `PlanPresentation.swift`: pure plan/route/comparison/format-access values.
- `VideoFormatMenu.swift`: native allowed and locked quality menu.
- `PlanComparisonView.swift`: local-only plan explanation.
- `SettingsView.swift`, `MediaOptionsSheet.swift`, and `DownloadCardView.swift`: consume the shared presentation values.

Build-channel ownership remains outside application behavior:

- `scripts/build_swift_2.sh`: explicit channel argument and compile define.
- `scripts/check_swift_bundle.py`: bundle/channel consistency.
- Existing Python tests under `tests/`: fail-closed packaging contracts.

## Review Focus

- A stale `internal-test-selected-plan=test-pro` preference on a public launch still produces Free and is never read by the public provider.
- Values such as ` test-pro`, `TEST-PRO`, numeric UserDefaults objects, and unknown strings fail closed to Free.
- A format with missing height, source wording, or 4K wording cannot become the Free default even when it appears first.
- A downgrade after scheduler selection but before Runner side effects is denied without creating a reservation, partial, temporary output, or process.
- Repeated internal Free/Test Pro changes while analysis or retry is suspended publish only the newest state and never auto-start newly unlocked work.

## Execution Preflight

- [ ] Confirm this worktree contains only the committed spec/plan changes and no unrelated files.
- [ ] Run the existing strict Swift suite with a project-local Clang module cache.
- [ ] Create this plan's SDD ledger and record shared interfaces: Task 1 produces `PlanController`; Tasks 2-5 consume it. Task 2 produces restricted-job state; Tasks 4-5 present and reconcile it. Task 3 produces format access; Task 4 routes its locked action.

Run:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: the existing suite exits 0 before the first RED change.

---

### Task 1: Build-Gated Plan Controller And Providers

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/AppPlan.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanProvider.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanController.swift`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/PlanControllerTests.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`

**Interfaces:**
- Produces: `AppBuildChannel.publicRelease`, `.internalTest`, and compile-time `current`.
- Produces: `AppPlan.free`, `.testPro`, and `featurePolicyContext`.
- Produces: `PlanProviding.loadPlan() -> AppPlan`, `PublicFreePlanProvider`, `InternalTestPlanStore`, and `InternalTestPlanProvider`.
- Produces: `@MainActor PlanController.currentPlan`, `buildChannel`, `featurePolicyContext`, and `internalSwitchingAvailable`.
- Under `YTDP_INTERNAL_TEST`, produces `PlanController.selectInternalPlan(_:)` and `resetInternalPlanToFree()`.
- Task 2 consumes the controller's current immutable `FeaturePolicyContext`; Tasks 3-5 observe the same controller.

- [ ] **Step 1: Add RED tests for public Free and fail-closed internal persistence**

Create `PlanControllerTests.swift` with real `UserDefaults` suites removed in `tearDown`:

```swift
@MainActor
final class PlanControllerTests: XCTestCase {
    func testPublicProviderAlwaysProducesEnforcedFree() {
        let controller = PlanController(
            buildChannel: .publicRelease,
            provider: PublicFreePlanProvider()
        )
        XCTAssertEqual(controller.currentPlan, .free)
        XCTAssertEqual(controller.featurePolicyContext.plan, .free)
        XCTAssertFalse(controller.internalSwitchingAvailable)
    }

    func testInternalStoreAcceptsOnlyExactKnownStrings() {
        for (stored, expected) in [
            ("free", AppPlan.free), ("test-pro", .testPro),
            (" test-pro", .free), ("TEST-PRO", .free), ("unknown", .free)
        ] {
            defaults.set(stored, forKey: InternalTestPlanStore.key)
            XCTAssertEqual(InternalTestPlanStore(defaults: defaults).loadPlan(), expected)
        }
        defaults.set(1, forKey: InternalTestPlanStore.key)
        XCTAssertEqual(InternalTestPlanStore(defaults: defaults).loadPlan(), .free)
    }
}
```

Expected RED command:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter PlanControllerTests \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: compilation fails because the plan types do not exist.

- [ ] **Step 2: Add the minimal plan and provider values**

Implement these exact contracts:

```swift
enum AppBuildChannel: String, Equatable, Sendable {
    case publicRelease = "public"
    case internalTest = "internal-test"

    static var current: Self {
        #if YTDP_INTERNAL_TEST
        .internalTest
        #else
        .publicRelease
        #endif
    }
}

enum AppPlan: String, Codable, Equatable, Sendable {
    case free
    case testPro = "test-pro"

    var featurePolicyContext: FeaturePolicyContext {
        .enforced(FeaturePolicy(snapshot: self == .free ? .syntheticFree : .syntheticPro))
    }
}

protocol PlanProviding {
    func loadPlan() -> AppPlan
}
```

`PublicFreePlanProvider.loadPlan()` returns `.free`. `InternalTestPlanStore.loadPlan()` reads `object(forKey:) as? String` and accepts only exact `AppPlan(rawValue:)`; its save method writes only an `AppPlan.rawValue`. `InternalTestPlanProvider` delegates to that store.

- [ ] **Step 3: Add the minimal main-actor controller and verify GREEN**

```swift
@MainActor
final class PlanController: ObservableObject {
    @Published private(set) var currentPlan: AppPlan
    let buildChannel: AppBuildChannel
    private let internalStore: InternalTestPlanStore?

    var featurePolicyContext: FeaturePolicyContext { currentPlan.featurePolicyContext }
    var internalSwitchingAvailable: Bool { buildChannel == .internalTest }
}
```

The initializer loads exactly once from the injected provider. `live(defaults:)` chooses `PublicFreePlanProvider` in public compilation and `InternalTestPlanProvider` only under `YTDP_INTERNAL_TEST`.

Run the focused command again. Expected: all non-conditional `PlanControllerTests` pass.

- [ ] **Step 4: Add RED/GREEN internal mutation coverage under the compile flag**

Guard tests and APIs with `#if YTDP_INTERNAL_TEST`. Tests prove Free -> Test Pro publishes immediately, persists exact `test-pro`, reset returns to Free, and a `.publicRelease` controller refuses mutation even in an internal test compilation.

Run:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" \
  swift test --package-path swift-2.0 --disable-sandbox \
  --filter PlanControllerTests -Xswiftc -DYTDP_INTERNAL_TEST \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: conditional tests pass after the smallest mutation implementation.

- [ ] **Step 5: Inject the controller at the app root**

`AppLifecycle` constructs `PlanController.live()` independently from `AccountSessionStore`; both `WindowGroup` and `Settings` receive `.environmentObject(appLifecycle.planController)`. Do not yet change `DownloadStore` admission or views.

- [ ] **Step 6: Run Task 1 completion verification and commit**

Run both focused variants, then the full strict suite without the internal flag. Expected: all pass and `git diff --check` is clean.

Commit:

```bash
git add swift-2.0/Sources/YTDownloaderPro2/Entitlements/AppPlan.swift \
  swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanProvider.swift \
  swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanController.swift \
  swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift \
  swift-2.0/Tests/YTDownloaderPro2Tests/PlanControllerTests.swift
git commit -m "feat(swift): add build-gated plan controller"
```

---

### Task 2: Store And Runner Policy Enforcement

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadJob.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadCoordinator.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadRunner.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/App/YTDownloaderPro2App.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadRunnerTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/ModelsTests.swift`

**Interfaces:**
- Consumes: `PlanController.featurePolicyContext` from Task 1.
- Produces: `DownloadAccessRequirement(feature:reason:)` and optional `DownloadJob.accessRequirement`.
- Produces: Runner invocation with an immutable `FeaturePolicyContext` captured at the final pre-side-effect boundary.

- [ ] Write RED model tests proving backward-compatible decoding defaults `accessRequirement` to nil and encoded requirements contain only feature and reason.
- [ ] Add `DownloadAccessRequirement`, optional job storage, and scrubbing-safe Codable behavior; rerun model tests GREEN.
- [ ] Write RED Store tests for URL, playlist, job creation/edit, recovery, resume, and retry admission under Free, including zero placeholder/job side effects on denial.
- [ ] Replace the Store's immutable `featurePolicyContext` with a `PlanController` dependency and evaluate `planController.featurePolicyContext` at each command boundary.
- [ ] Write RED Runner tests proving a denied 1080p/source/unknown-height job performs zero scope, allocator, temp, and process side effects.
- [ ] Pass the latest immutable context to Runner immediately before execution and return a typed policy denial distinct from operational failure.
- [ ] Run focused Store, Runner, model tests and full strict suite; commit `feat(swift): enforce plan policy at store and runner boundaries`.

---

### Task 3: Locked Video Format Presentation

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/PlanPresentation.swift`
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/VideoFormatMenu.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/MediaOptionsSheet.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/OptionsPresentationTests.swift`

**Interfaces:**
- Consumes: `PlanController.featurePolicyContext`.
- Produces: `VideoFormatAccess.allowed(MediaFormat)` and `.locked(MediaFormat, FeatureDenial)`.
- Produces: `VideoFormatMenu` callbacks `onSelect(String?)` and `onRequestUpgrade(FeatureDenial)`.

- [ ] Add RED pure presentation tests for 720p allowed; 1080p, 1440p, 4K/source, and unknown height locked; MP3 unaffected; no artificial rows; highest eligible Free default.
- [ ] Implement pure classification and normalization with no SwiftUI or side effects; rerun GREEN.
- [ ] Add RED interaction tests proving locked activation preserves selection and emits only a sanitized denial.
- [ ] Replace the video `Picker` with `VideoFormatMenu`; retain native audio controls and stable checkmark/label/lock dimensions.
- [ ] Add accessibility labels for quality and Requires Pro state, plus keyboard activation coverage.
- [ ] Run focused presentation tests and full strict suite; commit `feat(swift): present locked Pro video formats`.

---

### Task 4: Plan Comparison, Settings, And Localized Routing

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/PlanComparisonView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/PlanPresentation.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCenterView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DownloadCardView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`
- Create: `swift-2.0/Tests/YTDownloaderPro2Tests/PlanPresentationTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`

**Interfaces:**
- Consumes: locked-format denials and restricted-job requirements from Tasks 2-3.
- Produces: sanitized `UpgradePresentationRoute` with locked quality, batch, playlist, advanced subtitles, restricted job, and Settings cases.
- Produces: local-only `PlanComparisonPresentation` and Settings plan section.

- [ ] Add RED route tests proving no route stores URL, title, path, cookie, format ID, thumbnail, diagnostics, or account identity.
- [ ] Add RED three-locale tests for plan names, quality limits, lock labels, comparison rows, unavailable-upgrade copy, and restricted job state.
- [ ] Implement pure presentations and localization; rerun GREEN.
- [ ] Add the Settings Plan section and shared local comparison sheet with only Close as an action; do not show a price or external command.
- [ ] Route locked formats, policy denial actions, and restricted cards through the same sheet while preserving current media selections.
- [ ] Run focused presentation/localization tests and full strict suite; commit `feat(swift): add local Free and Pro plan experience`.

---

### Task 5: Internal Plan Switching And Queue Reconciliation

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Entitlements/PlanController.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/MediaOptionsSheet.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/PlanControllerTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`
- Modify: `swift-2.0/Tests/YTDownloaderPro2Tests/OptionsPresentationTests.swift`

**Interfaces:**
- Consumes: controller, restricted state, format access, and routes from Tasks 1-4.
- Produces: deterministic downgrade/upgrade reconciliation and internal-only Settings controls.

- [ ] Add RED tests for rapid plan changes, persisted restart, public stale-preference immunity, and invalid-data Free fallback.
- [ ] Add RED Store race tests: active work continues; queued/paused/retry Pro-only work blocks; upgrade makes it manually resumable but does not auto-start.
- [ ] Observe controller changes in Store and reconcile only non-active jobs against the newest generation.
- [ ] Under `#if YTDP_INTERNAL_TEST`, add the Settings Free/Test Pro segmented control, disclaimer, and Reset to Free; public compilation contains no section.
- [ ] Normalize an open options selection after downgrade to the highest eligible Free choice and emit one local notice without closing the sheet.
- [ ] Verify internal and public compilations separately, then the full strict suite; commit `feat(swift): reconcile internal plan changes safely`.

---

### Task 6: Explicit Public And Internal Packaging Channels

**Files:**
- Modify: `scripts/build_swift_2.sh`
- Modify: `scripts/check_swift_bundle.py`
- Modify: `tests/test_build_swift_2_script.py`
- Modify: `tests/test_swift_bundle.py`
- Modify: `docs/swift-2.0/ARCHITECTURE.md`
- Modify: `docs/swift-2.0/DEVELOPMENT.md`
- Modify: `docs/swift-2.0/ENTITLEMENT_ARCHITECTURE.md`

**Interfaces:**
- Consumes: compile flag and `AppBuildChannel.current` from Task 1.
- Produces: required `--app-channel public|internal-test`, matching `YTDPBuildChannel`, channel-specific output paths, ZIP names, and reports.

- [ ] Add RED Python tests for missing/unknown channels, flag wiring, Info.plist metadata, mismatched bundle reports, and separate artifacts.
- [ ] Parse `--app-channel` before tests or filesystem replacement; pass `-DYTDP_INTERNAL_TEST` only for internal Swift test/build invocations.
- [ ] Write `YTDPBuildChannel` into Info.plist and include channel in all artifact/report paths; update the verifier to fail closed.
- [ ] Document exact local commands, channel semantics, Test Pro disclaimer, and the continued absence of production entitlement/payment.
- [ ] Run Python packaging tests, both strict Swift channel suites, release compilation, bundle verification, helper execution, codesign validation, ZIP tests, SBOM tests, and `git diff --check`.
- [ ] Build separate owner-test public and internal candidates without publishing; commit `build(swift): separate public and internal plan channels`.

## Final Whole-Branch Verification

After all six commits:

1. Run the full strict Swift suite for public compilation.
2. Run the full strict Swift suite with `YTDP_INTERNAL_TEST`.
3. Run the complete Python test suite covering bundle and SBOM contracts.
4. Assemble both local channels and verify metadata, binaries, helpers, licenses, source-availability files, signatures, symlink/inode rules, writable-state rules, and archives.
5. Perform the 13 manual acceptance checks in the spec on fresh local application state.
6. Review the complete branch against the spec, classify findings, and fix every Critical or Important issue through a new RED/GREEN cycle.
7. Confirm no credential, media, diagnostic payload, generated app, ZIP, cache, or unrelated worktree file is staged.

Passing this plan authorizes only review of local candidates. It does not authorize a push, pull request, merge, tag, release, notarization, public claim, login activation, backend deployment, payment configuration, or other external action.
