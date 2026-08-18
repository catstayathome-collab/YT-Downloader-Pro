# Task 5 Report: Streaming Process Events And Progress Parsing

## Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadEvent.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Process/ProcessLauncher.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Process/SystemProcessLauncher.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/ProgressParser.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/ProgressParserTests.swift`

## TDD Evidence

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProgressParserTests`

The focused suite failed before implementation because `ProgressParser`, `ProcessLineBuffer`, the event models, and `SystemProcessLauncher.start` did not exist.

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProgressParserTests/testPreservesProgressEventWhenTemplateNumericFieldsAreMissing`

The focused regression failed with `[]` instead of a `DownloadEvent.progress` whose numeric values were all `nil`, proving that a missing `N/A` percentage incorrectly discarded the structured event.

### GREEN

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProgressParserTests`

Passed: 11 tests, 0 failures. Coverage includes structured MP4/MP3 phase templates, percent whitespace and clamping, missing or invalid values, sanitized human diagnostics, split UTF-8 chunks, EOF final lines, both pipes before one termination event, and idempotent interrupt/terminate signals.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ToolchainTests`: 11 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter YouTubeStrategyTests`: 7 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MetadataProbeTests`: 8 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 62 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/ytdp-task5-concurrency-final -Xswiftc -strict-concurrency=complete`: 62 tests, 0 failures.

## Implementation Notes

- `ProcessRunning.run` remains available and returns the complete raw stdout and stderr after both pipes have reached EOF.
- `ProcessLaunching.start` returns an actor-isolated `RunningProcess` with one `AsyncStream<ProcessEvent>`. The stream emits ordered lines within each pipe, then exactly one termination event, and finishes exactly once.
- The line buffer retains raw bytes until a newline or EOF, so split UTF-8 sequences and unterminated final lines are preserved.
- Signal methods are idempotent and only operate while the locked process reference is still running.
- Structured stdout templates alone drive typed progress. Human stderr is only emitted as a sanitized diagnostic, with a narrowly matched merger fallback phase.

## Commit

`feat(swift): stream structured download progress`

## Concerns

- `Foundation.Process` supplies no stronger atomic PID-liveness primitive than its process state API. Signals are serialized with termination handling and guarded by `isRunning`, but the operating system remains the final authority over a process that exits between checks.

## Fix Round 1: Waiters, Filepaths, And Process-State Signaling

### Root Cause

- `ProcessController` retained one `result()` continuation, so a second concurrent waiter replaced the first and leaked it.
- The parser split the entire `ytdp:filepath` line on every pipe character, rejecting legal absolute paths that contain `|`.
- Signal requests checked `Process.isRunning` under a lock but did not retain an explicit observed-termination state.

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProgressParserTests`

The focused suite executed 13 tests with two failures: the concurrent two-waiter regression timed out after two seconds and Swift reported a leaked continuation; a filepath containing literal pipes produced no output event.

### GREEN

- `result()` retains every pre-completion continuation and resumes every waiter exactly once. A caller after completion receives the stored result immediately.
- `ytdp:filepath` removes only its known prefix, retaining all later pipe characters.
- The controller sets `childTerminated` while holding the same lock used for signals. It rejects later signals after that observation, while retaining the unavoidable race between `Foundation.Process.isRunning` and operating-system signal delivery.
- The deterministic high-volume fixture writes 4,096 lines to each pipe, checks both per-pipe orders, requires one final termination event, and has a five-second timeout.

### Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProgressParserTests`: 13 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-build --filter ProgressParserTests`: 20 consecutive runs, 13 tests each, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 64 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/ytdp-task5-fix-round-1-concurrency -Xswiftc -strict-concurrency=complete`: 64 tests, 0 failures.

### Commit

`fix(swift): harden streaming process waits`
