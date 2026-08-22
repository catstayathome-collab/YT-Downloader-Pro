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
- Relevant Python regression set excluding the unavailable YAML-dependent module
  passed 180 tests:
  `tests.test_core`, `test_downloader`, `test_entrypoints`, `test_platforms`,
  `test_selftest`, `test_settings`, `test_toolchain`, `test_updater`,
  `test_version_sources`, `test_windows_build_scripts`, and `test_windows_docs`.
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

- `tests.test_windows_workflow` could not load because the existing local test
  environments do not contain pinned `PyYAML==6.0.3`. Installing it would require
  prohibited network access. The other 180 Python tests passed, including all
  update, entrypoint, Windows build, and documentation tests that can run locally.
- No live GitHub response or public package checksum was tested by design. Release
  values and live Contents API behavior remain Task 15/release-gate work.
- Windows x64 selection is unit-tested on macOS; an actual packaged Windows update
  remains subject to the Windows acceptance workflow.
