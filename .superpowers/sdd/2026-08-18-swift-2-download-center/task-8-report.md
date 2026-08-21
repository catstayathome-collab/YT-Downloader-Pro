# Task 8 Report: Dynamic Download Coordinator

## Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadCoordinator.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCoordinatorTests.swift`
- `.superpowers/sdd/2026-08-18-swift-2-download-center/task-8-report.md`

## RED/GREEN Evidence

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadCoordinatorTests`

Before production code existed, the new test target failed to compile because `DownloadCoordinator` and `CoordinatorEvent` were missing. The suite defined the required queue limits, FIFO coordinator-event ordering, Start Now promotion, worker isolation, pause/cancel/resume idempotence, terminal event ordering, and shutdown behavior.

### GREEN

The final focused coordinator run passed all 14 tests. The implementation uses `nonisolated let events: AsyncStream<CoordinatorEvent>`, tracks one child task per active job, never uses `Task.detached`, and shuts down with a structured task group for runner interruption followed by awaiting every active child task.

## Verification

- Baseline `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 102 tests, 0 failures.
- RED `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadCoordinatorTests`: compile failure due to missing coordinator types.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadCoordinatorTests`: 14 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadRunnerTests`: 20 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 116 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete`: 116 tests executed; 115 passed and 1 failed in the unchanged `PersistenceControllerTests.testNonFlushSavesCoalesceToLatestSnapshot`.
- `git diff --check`: clean.

## Commit

`feat(swift): schedule concurrent download jobs`

## Concerns

- The strict-concurrency build completed and all 14 coordinator tests passed. Its final full-suite result is blocked by the pre-existing fixed-delay persistence coalescing test above; it is unchanged from `dced5c3`, passed the ordinary full run, and was observed to be intermittent during this task. No persistence code or test was modified.
- `JobRunning.events(for:)` starts its own stream asynchronously, so the defined deterministic boundary is `CoordinatorEvent.started`; tests assert FIFO at that boundary while testing concurrently admitted runner jobs as sets.

## Fix Round 1

### Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadCoordinator.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadCoordinatorTests.swift`
- `.superpowers/sdd/2026-08-18-swift-2-download-center/task-8-report.md`

### RED Evidence

`swift test --filter DownloadCoordinatorTests`

The focused suite compiled and executed 16 tests. The 14 existing tests passed, while both new deterministic regressions failed as intended (8 assertion failures total): overlapping shutdown callers returned while pause/cancel cleanup was blocked, no stopped events reached the already-finished stream, and a buffered merge transition received no authoritative quit interruption.

### GREEN Evidence

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadCoordinatorTests`: 16 tests, 0 failures.
- Coordinator repetition: 10 consecutive focused runs, 160 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete --filter DownloadCoordinatorTests`: 16 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadRunnerTests`: 20 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 118 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete`: 118 tests, 0 failures.
- `git diff --check`: clean.

### Fix Details

- Active jobs now retain their in-flight pause/cancel control task until both runner cleanup and worker termination complete.
- Every shutdown caller joins the same drain; shutdown snapshots and awaits all active workers, including workers that already have a stop command in flight, before finishing `events`.
- Active pause and shutdown use the existing authoritative `interruptForQuit` runner operation, removing coordinator decisions based on a potentially buffered phase event while preserving the approved `JobRunning` interface.
- All coordinator-test polling helpers now have two-second deadlines and condition-specific timeout messages.

### Commit

`fix(swift): harden coordinator shutdown`

### Concerns

- `interruptForQuit` is intentionally used for active pause as the existing atomic safe-interruption API: it uses normal interrupt/pause cleanup while downloading and merge-safe quit cleanup after the runner has authoritatively entered merging or postprocessing.
- The previously reported persistence debounce test passed in both full runs during this fix round; its underlying fixed-delay sensitivity remains unrelated and unchanged.
