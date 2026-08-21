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
