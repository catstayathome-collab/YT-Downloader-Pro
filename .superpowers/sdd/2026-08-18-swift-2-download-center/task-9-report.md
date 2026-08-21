# Task 9 Report: Thumbnail Cache And Sanitized Diagnostics

## Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/ThumbnailCache.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/DiagnosticsLogger.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/ThumbnailCacheTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift`
- `.superpowers/sdd/2026-08-18-swift-2-download-center/task-9-report.md`

## RED/GREEN Evidence

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DiagnosticsLoggerTests`

Before production code existed, the focused build failed because `DiagnosticsLogger` and `DiagnosticEvent` were missing.

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ThumbnailCacheTests`

Before production code existed, the focused build failed because `ThumbnailCache`, `ThumbnailCacheError`, `ThumbnailDataLoader`, and `ThumbnailDownload` were missing.

### GREEN

- `DiagnosticsLoggerTests`: 3 tests, 0 failures.
- `ThumbnailCacheTests`: 6 tests, 0 failures.
- The thumbnail loader is an injected `@Sendable` dependency in every network-path test, so the test suite makes no thumbnail network requests.
- The diagnostics serializer writes one sanitized Codable event per JSONL line, strips sensitive flag values, cookie paths and values, authorization material, and URL query values before serialization, and rotates at 5 MB while retaining three rotated files.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DiagnosticsLoggerTests`: 3 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ThumbnailCacheTests`: 6 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 127 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/ytdp-task9-strict-concurrency -Xswiftc -strict-concurrency=complete`: 127 tests, 0 failures.
- `git diff --check`: clean.

## Commit

`feat(swift): cache thumbnails and sanitize diagnostics`

## Concerns

- Task 9 provides cache and diagnostics services only. DownloadStore wiring, including removing thumbnails when records are cleared, remains Task 10 scope.

## Fix Round 1

### Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/DiagnosticsLogger.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/ThumbnailCache.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/DiagnosticsLoggerTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/ModelsTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/ThumbnailCacheTests.swift`
- `.superpowers/sdd/2026-08-18-swift-2-download-center/task-9-report.md`

### Review Findings Addressed

- Shared diagnostic redaction now structurally removes URL userinfo, passwords, all query values, complete fragments, proxy credentials, short and long credential flags, cookie arguments and local cookie-file paths, authorization material, and credentials embedded in prose/output while preserving hosts, paths, query keys, status text, and case-sensitive non-secret options.
- Thumbnail validation now requires ImageIO to decode frame zero and derives PNG, JPEG, GIF, or WebP storage type from the decoded source type. Truncated and signature-spoofed data for all four formats is rejected.
- Thumbnail replacement stages and revalidates data in the cache directory, atomically installs it, and removes obsolete extensions only afterward. Injected write, staged-read, move, replace, and remove failures prove the prior thumbnail survives.
- Cache roots are canonicalized; directory and leaf symlinks are rejected for store, lookup, and deletion with containment checks repeated immediately before mutations.
- Diagnostics use an injected narrow filesystem abstraction. Existing-log read failures propagate and leave prior bytes unchanged.
- Rotation uses persistent preparing, committing, and cleanup phases with staged generations, rollback, and next-operation recovery. Valid uniquely identified JSONL events are tested below, exactly at, and above 5 MB and at every move/remove boundary; retained events decode once in current-to-oldest order.

### RED Evidence

- The new on-disk redaction regression initially reported 21 leaked credential, cookie-path, proxy, URL-query, and fragment values.
- The shared model redaction regression initially reported 14 leaked values. A final case-sensitivity regression then failed once because non-secret `-P /Users/example/Downloads` was incorrectly redacted as lowercase `-p`.
- The malformed-image regression initially failed four assertions because signature-only PNG, JPEG, GIF, and WebP payloads were accepted.
- Thumbnail durability and symlink tests initially failed to compile because the injected filesystem seam and unsafe-path error did not exist.
- Diagnostics read-failure and transactional-rotation tests initially failed to compile because the injected diagnostics filesystem did not exist.

### GREEN And Verification

- `DiagnosticsLoggerTests`, repeated during development and rerun after the final source change: 7 tests, 0 failures.
- `ThumbnailCacheTests`, repeated during development and rerun after the final source change: 11 tests, 0 failures.
- `ModelsTests`: 13 tests, 0 failures.
- Full suite: 138 tests, 0 failures.
- Full strict-concurrency suite using `-Xswiftc -strict-concurrency=complete`: 138 tests, 0 failures.
- Fresh `arm64-apple-macosx13.0` build: passed.
- Thumbnail network paths use injected deterministic loaders in tests; the test suite does not contact the network.
- Final `git diff --check`: clean.

### Commit

`fix(swift): harden thumbnail and diagnostic storage`

### Concerns

- No Task 9 review finding remains open. Recovery from a second independent filesystem failure during an already-failing thumbnail rollback is necessarily best-effort; normal single-failure boundaries are deterministic and covered.
- DownloadStore integration remains Task 10 scope, as noted above.

## Fix Round 2

### Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Services/ThumbnailCache.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/ThumbnailCacheTests.swift`
- `.superpowers/sdd/2026-08-18-swift-2-download-center/task-9-report.md`

### Remaining Findings Addressed

- Thumbnail installation intent is recorded before move/replace. Rollback now inspects the destination and replacement backup after any thrown mutation: a newly moved alternate extension is removed without touching the old file, while a same-extension replacement moves the preserved live backup back to the original destination. The backup remains available until the full transaction commits.
- Failed cross-extension and same-extension stores preserve the original bytes, file identity, extension/path, and lookup result; no new alternate thumbnail remains selectable.
- The cache retains both the configured root identity and canonical root. Every store, lookup, and deletion path revalidates the original configured root and rejects root symlinks or changed symlink resolution before touching `Thumbnails`.

### RED Evidence

- After correcting test-harness compile errors, `ThumbnailCacheTests` executed 16 tests and failed the five new behavior tests with 10 assertions: post-mutation move left `.jpg` and `.png` while lookup selected `.jpg`; post-mutation replace changed both bytes and file identity; configured-root symlinks were accepted by store, lookup, and deletion and mutated the outside target.
- The move and replace fault injectors call the live filesystem mutation first and throw only afterward, matching the re-review probes rather than simulating a pre-mutation error.

### GREEN And Verification

- `ThumbnailCacheTests`: 16 tests, 0 failures in three consecutive focused runs.
- `DiagnosticsLoggerTests`: 7 tests, 0 failures.
- `ModelsTests`: 13 tests, 0 failures.
- Full suite: 143 tests, 0 failures.
- Fresh full strict-concurrency suite using `-Xswiftc -strict-concurrency=complete`: 143 tests, 0 failures.
- Fresh `arm64-apple-macosx13.0` build: passed.
- Thumbnail network paths remain injected and deterministic in tests; the suite makes no thumbnail network requests.
- Final `git diff --check`: clean before commit.

### Commit

`fix(swift): preserve thumbnails after failed install`

### Concerns

- No scoped Task 9 re-review finding remains open. If rollback itself encounters a second independent filesystem failure, its error propagates and any live backup is deliberately retained for recovery instead of being deleted.
- DownloadStore integration remains Task 10 scope.
