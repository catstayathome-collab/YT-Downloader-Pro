# Task 14 Report: Split macOS and Windows update manifests

## Outcome

- Added a Swift `MacOSUpdateManifest`, strict SemVer 2.0 parser, injected-session
  `UpdateChecker`, and typed update results/failures.
- Added GitHub Contents API base64 decoding with fail-closed validation for the
  macOS platform, versions, minimum macOS, HTTPS URLs, lowercase SHA-256,
  publication timestamp, and release notes.
- Integrated automatic checks with `DownloadStore` and app launch. Disabled
  automatic checks do not call the service; automatic transient failures remain
  unpublished, while manual failures remain actionable through `UpdateResult`.
- Added deterministic `updates/macos.json` and `updates/windows.json` schema
  examples plus `scripts/create_macos_manifest.py` and maintainer documentation.
- Pointed future Python builds at the Windows Contents API manifest and added
  platform-aware Windows x64 asset selection. Legacy plain text and legacy JSON
  version sources remain supported, and root `version.txt` was not changed.

## TDD Evidence

1. Initial Swift RED: `swift test --filter 'UpdateCheckerTests|DownloadStoreTests'`
   failed because `UpdateChecker`, `UpdateSession`, `SemanticVersion`,
   `UpdateResult`, Store state, and Store injection did not exist.
2. Initial Python RED: `python -m unittest tests.test_updater
   tests.test_version_sources -v` failed because the platform parser, generator,
   and split manifests did not exist.
3. Lifecycle RED: the focused lifecycle test failed because
   `startAutomaticUpdateCheck()` did not exist; it passed after launch wiring was
   added.
4. Boundary RED: arbitrary-length SemVer and non-ASCII checksum tests produced
   two expected failures. The implementation now compares numeric identifiers as
   digit strings and accepts only ASCII `0-9a-f` checksums.
5. Focused GREEN: strict `UpdateCheckerTests|DownloadStoreTests` passed, and the
   required Python update/version-source suites passed 33 tests.

## Changed Files

- Swift implementation: `Services/UpdateChecker.swift`,
  `Stores/DownloadStore.swift`, `App/YTDownloaderPro2App.swift`.
- Swift tests: `UpdateCheckerTests.swift`, `DownloadStoreTests.swift`.
- Manifests and tooling: `updates/macos.json`, `updates/windows.json`,
  `updates/README.md`, `scripts/create_macos_manifest.py`.
- Python implementation: `ytdp/updater.py`, `ytdp/app.py`.
- Python tests: `tests/test_updater.py`, `tests/test_version_sources.py`, and
  `tests/__init__.py` so the plan's qualified unittest command is executable.

## Verification

- Full strict Swift suite:
  `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete
  -Xswiftc -warnings-as-errors` passed 257 tests with 0 failures.
- macOS 13 arm64 strict build:
  `swift build --disable-sandbox --triple arm64-apple-macosx13.0
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` passed.
- Required Python suites:
  `python3 -m unittest tests.test_updater tests.test_version_sources -v` passed
  33 tests.
- Complete Python discovery passed 186 tests with the existing
  `.worktrees/codex-release-1.8.7/.venv-1.8.7/bin/python`, which contains the
  pinned `PyYAML==6.0.3`. No installation or network access was required.
- `python3 -m json.tool` accepted both manifests.
- `python3 -m py_compile` accepted the changed Python implementation and generator.
- `git diff --check` passed.
- No test or implementation command contacted the network.

## Compatibility Notes

- New macOS code reads only `updates/macos.json`; it never reads `version.txt` or
  the Windows manifest.
- New Python update checks read `updates/windows.json` and require an exact
  `windows`/`x64` asset. A platform or architecture mismatch fails closed.
- Plain `version.txt`, legacy JSON version keys, and their release-asset fallback
  remain accepted for already-released clients and override/test deployments.
- Checked-in manifest values use `0.0.0`, `example.invalid`, zero checksums, and
  explicit placeholder notes. They do not claim that a release exists.

## Residual Risks

- No live GitHub response or public package checksum was tested by design. Release
  values and live Contents API behavior remain Task 15/release-gate work.
- Windows x64 selection is unit-tested on macOS; an actual packaged Windows update
  remains subject to the Windows acceptance workflow.

## Fix Round 1

### Resolved Findings

1. Added a localized Settings **Check for Updates** button and user-visible
   presentations for available, unsupported, up-to-date, and actionable failure
   results in English, Japanese, and Traditional Chinese. Automatic checks publish
   only available or unsupported notices. Release opening revalidates
   credential-free HTTPS before calling `NSWorkspace`.
2. Removed the production `2.0.0` bundle-version fallback. Missing or malformed
   `CFBundleShortVersionString` now reaches strict parsing and fails closed.
3. Added a MainActor-owned update generation and single-flight task. Duplicate
   automatic triggers coalesce; a manual request cancels and supersedes older work,
   and non-cooperative stale completions cannot overwrite the manual result.
4. Structured Windows selections now use strict SemVer precedence, including
   prerelease ordering and build-metadata equality. Legacy sources retain their
   historical numeric-component comparison.
5. Replaced Unicode-aware `\d` tokens in the Python structured parser and macOS
   generator with ASCII `[0-9]`, with Unicode-digit fixtures in Swift and Python.
6. The Swift checker validates the final response URL after redirects against
   HTTPS plus the requested API origin and path. It rejects Contents envelopes
   above 192 KiB and decoded manifests above 96 KiB before decoding further.
7. Corrected the Python environment record above and used the existing pinned
   venv for complete discovery without installation or network access.

### TDD Evidence

- Swift service/Store RED introduced missing bundle metadata, final redirect URL,
  oversized data, automatic visibility, duplicate-flight, and stale-completion
  cases before implementation. The focused GREEN suite passed afterward.
- Swift presentation RED failed on the absent notice model, localized keys,
  accessibility labels, and safe release command. The UI/localization GREEN suite
  passed after the production Settings and main-window paths were wired.
- Python RED showed structured prerelease/build comparisons had no SemVer-aware
  selection method, Unicode digits were accepted, and the app still called the
  legacy comparator. All focused cases passed after the compatibility split.

### Verification

- Focused strict Swift service/UI/Store/localization suite: 88 tests passed.
- Full strict Swift suite: 268 tests passed with zero failures.
- macOS 13 arm64 strict build passed with warnings treated as errors.
- Focused Python updater/version-source suites: 37 tests passed.
- Complete Python discovery using the existing `PyYAML 6.0.3` venv: 190 tests
  passed, comprising the prior 186 tests plus four new SemVer/Unicode tests.
- Both manifests and `Localizable.xcstrings` passed `python3 -m json.tool`.
- Changed Python sources and tests passed `python3 -m py_compile`.
- Regenerating the checked-in macOS placeholder produced byte-identical output.
- `git diff --check` passed. No network request or package installation occurred.

### Compatibility And Residual Risk

- Root `version.txt`, legacy plain/JSON parsing, release-asset fallback, TLS
  verification, and exact Windows x64 isolation remain intact.
- No live GitHub response, public checksum, signed bundle, released tag, or
  packaged Windows updater was exercised; those remain release-gate work.

## Fix Round 2

### Resolved Findings

1. Structured Python SemVer no longer converts core or numeric prerelease
   identifiers to integers. Canonical zero-trimmed digit strings are compared by
   length and then lexicographically, so valid identifiers above Python's digit
   conversion limit retain SemVer precedence and build metadata remains excluded
   from equality. Strict structured parsing still rejects leading-zero numeric
   prereleases; legacy sources retain their historical numeric semantics.
2. Replaced the Swift `URLSession.data(for:)` boundary with a Sendable streaming
   response/body contract and a macOS 13-compatible `URLSessionDataDelegate`
   transport. The live transport rejects oversized declared lengths at headers,
   validates the final HTTPS origin/path before allowing body bytes, and cancels
   on the first callback that would exceed 192 KiB. The checker independently
   bounds injected chunks and propagates task cancellation to the transport.

### TDD Evidence

- Python RED: the new 5,001-digit core and numeric prerelease tests each raised
  Python's `ValueError: Exceeds the limit (4300 digits)` at the existing
  `int(...)` conversions. The same focused class passed 23 tests after numeric
  string comparison was introduced.
- Swift RED: the chunk-stream fixtures failed to compile because
  `UpdateResponseBody`, `UpdateSessionResponse`, and the bounded `response(for:)`
  session contract did not exist. GREEN proves exact 192 KiB acceptance, rejection
  and cancellation at limit plus one, no request for later chunks after overflow,
  pre-body rejection for invalid final URLs and declared lengths, consumer-task
  cancellation, and Sendable conformance. Existing Store tests continued to prove
  automatic single-flight and manual supersession of stale results.

### Changed Files

- Swift transport and checker: `swift-2.0/Sources/YTDownloaderPro2/Services/UpdateChecker.swift`.
- Swift streaming tests: `swift-2.0/Tests/YTDownloaderPro2Tests/UpdateCheckerTests.swift`.
- Python SemVer and tests: `ytdp/updater.py`, `tests/test_updater.py`.
- Maintainer contract: `updates/README.md`.

### Verification

- Focused strict Swift service/UI/Store/localization suite: 94 tests passed.
- Full strict Swift suite: 274 tests passed with zero failures.
- macOS 13 arm64 strict build passed with warnings treated as errors.
- Focused pinned Python updater/version-source suites: 40 tests passed.
- Complete discovery with Python 3.13.2 and pinned PyYAML 6.0.3: 193 tests passed.
- Both manifests and `Localizable.xcstrings` passed `python3 -m json.tool`;
  changed Python files passed `python3 -m py_compile`.
- Regenerating the checked-in macOS placeholder with its exact fields was
  byte-identical. `git diff --check` passed on the report-inclusive tree.
- No package was installed and no network request was made.

### Compatibility And Residual Risk

- UI result visibility, Store generation/single-flight behavior, root
  `version.txt`, legacy plain/JSON comparison, release-asset fallback, TLS
  verification, and Windows x64 isolation are unchanged.
- The delegate transport is deterministic at its injected stream boundary and
  compiled for macOS 13 arm64, but no live GitHub response was exercised by
  design. Signed bundles, public checksums, released tags, and packaged Windows
  acceptance remain release-gate work.
