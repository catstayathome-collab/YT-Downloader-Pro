# Swift Local Support And Data Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add privacy-safe SwiftUI flows for composing a local support report, exporting sanitized local app data, and explicitly clearing selected local data without silently uploading information or deleting downloaded media.

**Architecture:** Keep policy-bearing draft models side-effect free, place filesystem mutations behind small injected services, and expose only narrow `DownloadStore` commands to SwiftUI. The settings window presents separate Support and Data Management sheets; every destructive action requires an action-specific preview and confirmation, while support/export writes are initiated through a user-selected local directory.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit panels, Foundation actors and protocols, XCTest, strict Swift concurrency.

**Spec:** `SUPPORT_REPORT_AND_DATA_REQUESTS.md`

## Global Constraints

- macOS 13 or newer; do not add third-party dependencies.
- No support vendor, email sender, upload endpoint, account backend, analytics, or network submission.
- Optional support fields start disabled and the final preview shows the exact encoded payload.
- Exported jobs and settings must use `LocalDataExportDraft` sanitization; never export Keychain tokens, bookmarks, cookies, media paths, remote thumbnail URLs, or downloaded files.
- History cleanup never deletes downloaded media. Media deletion is a separately named, separately confirmed user-selected-file action.
- All filesystem mutation targets must be local file URLs selected or derived inside app-owned storage.
- New behavior follows red-green-refactor and must pass strict concurrency with warnings as errors.

---

### Task 1: Local File Writers And Maintenance Boundaries

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Services/LocalSupportDataServices.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalSupportDataServicesTests.swift`

**Interfaces:**
- Consumes: `SupportReportDraft`, `LocalDataExportDraft`.
- Produces: `LocalSupportReportWriter.write(_:to:)`, `LocalExportPackageWriter.write(_:to:)`, and `SelectedMediaFileDeleter.delete(_:)`.

- [x] **Step 1: Write failing writer tests**

  Test that the support writer creates exactly one JSON file whose decoded payload equals the reviewed draft. Test that the export writer creates a package directory containing `manifest.json`, `jobs.json`, `settings.json`, `thumbnails.json`, and `diagnostics.json`, and that no media file is copied.

- [x] **Step 2: Run the focused tests and verify RED**

  Run:
  ```bash
  env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" swift test --package-path swift-2.0 --disable-sandbox --filter LocalSupportDataServicesTests -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  ```
  Expected: compile failure because the writer types do not exist.

- [x] **Step 3: Implement atomic local writers**

  Implement value-type writers with injected `FileManager`, sorted-key pretty JSON, collision-safe names, a staging directory for exports, and cleanup on failure. Reject non-file destinations. Return the final local URL and perform no network work.

- [x] **Step 4: Write failing selected-media deletion tests**

  Cover an existing regular file, a missing file, a directory, and a symbolic link. Only an explicitly selected existing regular file may be removed.

- [x] **Step 5: Implement the selected-media deleter and rerun focused tests**

  `SelectedMediaFileDeleter.delete(_:)` must reject non-file URLs, directories, and symlinks before calling `removeItem`.

- [x] **Step 6: Commit**

  ```bash
  git add swift-2.0/Sources/YTDownloaderPro2/Services/LocalSupportDataServices.swift swift-2.0/Tests/YTDownloaderPro2Tests/LocalSupportDataServicesTests.swift
  git commit -m "feat: add local support data services"
  ```

### Task 2: Store Commands For Export And Scoped Deletion

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/AppSettings.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Services/DiagnosticsLogger.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/AppSettingsTests.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadStoreTests.swift`

**Interfaces:**
- Consumes: current jobs, settings, thumbnails, persistence, and diagnostics already owned by `DownloadStore`.
- Produces: `makeLocalExportDraft(...)`, `clearCompletedHistory()`, `clearFailedAndCancelledHistory()`, `clearDiagnostics()`, and `resetSettings()`.

- [x] **Step 1: Write failing settings and diagnostics tests**

  Prove `AppSettingsStore.reset()` removes the persisted preference and `DiagnosticsLogger.clear()` removes only the known diagnostic logs, rotation marker, and rotation backups under the diagnostics directory.

- [x] **Step 2: Run the focused tests and verify RED**

  Expected: compile failures for the missing `reset` and `clear` methods.

- [x] **Step 3: Implement the narrow reset and diagnostic-clear operations**

  Keep both operations idempotent. Diagnostic cleanup must enumerate only the logger's fixed filenames and must never remove the diagnostics directory recursively.

- [x] **Step 4: Write failing scoped-history tests**

  Given completed, failed, cancelled, paused, queued, and downloading jobs, prove each scoped command removes only its allowed terminal statuses and related thumbnail cache entries while preserving every `outputURL` media file.

- [x] **Step 5: Implement one private scoped cleanup path**

  Reuse the existing coordinator-owned artifact cleanup and thumbnail removal behavior. Keep `clearHistory()` as the existing all-terminal command and delegate the two new public commands to a private status predicate.

- [x] **Step 6: Write failing local-export draft tests**

  Prove the store-created draft contains the current jobs/settings, bounded sanitized diagnostics, and no output path, cookie selection, bookmark bytes, or credential-bearing source URL.

- [x] **Step 7: Implement export-draft creation and reset commands**

  Read bounded diagnostic lines through `DiagnosticsLogger`, build `LocalDataExportDraft.defaultPreview`, and make resetting settings update both memory and persistence to `.defaults`.

- [x] **Step 8: Commit**

  ```bash
  git add swift-2.0/Sources/YTDownloaderPro2/Models/AppSettings.swift swift-2.0/Sources/YTDownloaderPro2/Services/DiagnosticsLogger.swift swift-2.0/Sources/YTDownloaderPro2/Stores/DownloadStore.swift swift-2.0/Tests/YTDownloaderPro2Tests
  git commit -m "feat: add scoped local data controls"
  ```

### Task 3: Support Report Composition And Exact Preview

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/SupportReportView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/DataRequestPresentation.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DataRequestPresentationTests.swift`

**Interfaces:**
- Consumes: user-entered category, subject, message, explicitly enabled optional values, and the current app environment.
- Produces: `SupportReportComposer` and a SwiftUI sheet that previews exact encoded JSON and saves it locally only after the user chooses a folder.

- [x] **Step 1: Write failing composer tests**

  Verify every optional field is nil by default, disabled fields stay absent even when text exists, enabled activity-revealing fields are marked in presentation, and the resulting draft preserves paid-priority bypass routing.

- [x] **Step 2: Run focused tests and verify RED**

  Expected: compile failure because `SupportReportComposer` is missing.

- [x] **Step 3: Implement the composer and preview presentation**

  Keep it a pure value type. It must build through `SupportReportDraft.defaultPreview`, then copy only explicitly enabled optional values into the draft.

- [x] **Step 4: Build the support sheet**

  Add category, subject, message, optional-field disclosure controls, a read-only exact JSON preview, a local-folder save button, success/failure feedback, accessibility labels, and explicit copy stating that no report is sent automatically.

- [x] **Step 5: Compile and run focused tests**

  Run strict focused tests and `swift build --package-path swift-2.0 --disable-sandbox`.

- [x] **Step 6: Commit**

  ```bash
  git add swift-2.0/Sources/YTDownloaderPro2/Views/SupportReportView.swift swift-2.0/Sources/YTDownloaderPro2/Views/DataRequestPresentation.swift swift-2.0/Tests/YTDownloaderPro2Tests/DataRequestPresentationTests.swift
  git commit -m "feat: add local support report flow"
  ```

### Task 4: Data Export And Destructive Data Management SwiftUI

**Files:**
- Create: `swift-2.0/Sources/YTDownloaderPro2/Views/LocalDataManagementView.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/DataRequestPresentationTests.swift`

**Interfaces:**
- Consumes: `DownloadStore` local export and scoped deletion commands plus Task 1 writers.
- Produces: separate local-export and data-management sheets reachable from Settings.

- [x] **Step 1: Write failing action-presentation tests**

  Define stable labels, symbols, confirmation severity, retained-data copy, enabled state, and media-deletion separation for every `LocalDeletionDraft.Action`.

- [x] **Step 2: Run focused tests and verify RED**

  Expected: assertions fail because the action presentation does not yet exist.

- [x] **Step 3: Implement export UI**

  Show sanitized section and record counts before writing. Use `NSOpenPanel` only to choose a local destination folder, then call `LocalExportPackageWriter`; reveal the completed package only on an explicit button press.

- [x] **Step 4: Implement data-management UI**

  Present separate rows and confirmation dialogs for completed history, failed/cancelled history, diagnostics, settings, and selected media file. Disable empty history actions. Media deletion requires `NSOpenPanel`, displays only the selected filename in confirmation, and never runs through a history action.

- [x] **Step 5: Wire Settings navigation**

  Add distinct Support and Data sections with icon buttons that present the sheets. Do not add external links or network actions.

- [x] **Step 6: Compile and run focused tests**

  Verify strict compilation and presentation tests.

- [x] **Step 7: Commit**

  ```bash
  git add swift-2.0/Sources/YTDownloaderPro2/Views/LocalDataManagementView.swift swift-2.0/Sources/YTDownloaderPro2/Views/SettingsView.swift swift-2.0/Tests/YTDownloaderPro2Tests/DataRequestPresentationTests.swift
  git commit -m "feat: add local data management settings"
  ```

### Task 5: Localization, Documentation, And Release-Grade Verification

**Files:**
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift`
- Modify: `swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings`
- Modify: `docs/swift-2.0/ARCHITECTURE.md`
- Modify: `docs/swift-2.0/DEVELOPMENT.md`
- Modify: `SUPPORT_REPORT_AND_DATA_REQUESTS.md`
- Test: `swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift`

**Interfaces:**
- Consumes: all user-visible controls introduced by Tasks 3 and 4.
- Produces: complete English, Traditional Chinese, and Japanese strings plus maintainer documentation.

- [ ] **Step 1: Write failing localization coverage tests**

  Add every new key to the required-key test and assert all three supported locales produce nonempty, non-key output.

- [ ] **Step 2: Run localization tests and verify RED**

  Expected: failures for missing keys.

- [ ] **Step 3: Add translations and maintenance documentation**

  Document service ownership, local-only boundaries, file formats, deletion guarantees, tests, and the explicit future gate for external support/account backends.

- [ ] **Step 4: Run complete verification**

  ```bash
  env CLANG_MODULE_CACHE_PATH="$PWD/swift-2.0/.build/clang-module-cache" swift test --package-path swift-2.0 --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
  PYTHONPATH=/private/tmp/ytdp-test-deps python3 -m unittest discover -s tests -v
  ./scripts/build_swift_2.sh --version 2.0.0 --architectures arm64 --sbom-created 2026-09-19T00:00:00Z --unsigned-test
  git diff --check
  ```

- [ ] **Step 5: Manually inspect the built Settings flows**

  Confirm no text overlaps at the minimum Settings window size, keyboard focus reaches every control, local save panels appear, no network request is made, and every delete confirmation describes retained data.

- [ ] **Step 6: Commit**

  ```bash
  git add swift-2.0/Sources/YTDownloaderPro2/Models/Localization.swift swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings docs/swift-2.0 SUPPORT_REPORT_AND_DATA_REQUESTS.md swift-2.0/Tests/YTDownloaderPro2Tests/LocalizationTests.swift
  git commit -m "docs: document local support data flows"
  ```
