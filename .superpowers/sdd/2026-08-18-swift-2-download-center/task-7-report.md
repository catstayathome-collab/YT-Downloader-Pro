# Task 7 Report: Download Runner, Pause, Cancel, And Retry

## Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadError.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Models/DownloadEvent.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/DownloadRunner.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/OutputNameAllocator.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/DownloadRunnerTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/fake-yt-dlp.sh`

## RED/GREEN Evidence

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadRunnerTests`

The new suite failed before production implementation. The compiler reported that `DownloadRunner` did not exist, and the tests also exposed the missing `.analyzing` phase, `.reservedBasename` event, and `.formatReselectionRequired` failure category.

### GREEN

The deterministic shell fixture drives the real `SystemProcessLauncher` without contacting YouTube. `DownloadRunnerTests` passed 11 tests covering verified completion, zero-exit-without-output rejection, pause/resume reservation retention and `--continue`, merge pause rejection, exact cancel cleanup, quit merge cleanup, bounded 403 reanalysis, non-retryable failure handling, format reselection, duplicate launch and consumer cancellation cleanup, and launch-failure cleanup.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadRunnerTests`: 11 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProgressParserTests`: 13 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`: 18 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 93 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete`: 93 tests, 0 failures.
- `git diff --check`: clean.

## Commit

`feat(swift): run and control individual downloads`

## Concerns

- Cleanup deliberately uses a finite set of exact reservation-derived artifact paths. Task 15 should validate that real bundled yt-dlp artifact naming covers every partial, fragment, and postprocessing temporary file across representative MP4 and MP3 downloads before release.
- The runner emits the reserved basename for Task 8 to persist onto `DownloadJob`; Task 8 must retain that event before treating a started job as durable.

## Fix Round 1

### Changes

- Retry reanalysis now launches through `ProcessLaunching`, occupies the active `RunningProcess` slot, and reuses `MetadataProbe` request construction, failure mapping, and JSON decoding. Pause, cancel, quit, and consumer termination therefore signal and await the same helper process.
- Launch arguments now retain the resolved security-scoped reservation directory through `DownloadJob.outputURL`, rather than falling back to a display path that may have moved or resolved through a different symlink.
- Cancel and quit wait for process exit, ownership-aware cleanup, reservation release, and security-scope release. Completion waiters are resumed after terminal cleanup and remain idempotent across repeated control calls.
- Artifact deletion is performed only while `OutputNameAllocator` holds the candidate lock and confirms the marker still belongs to the job. Exact enumeration includes owned `.part`, `.ytdl`, and numeric `.part-Frag*` fragments without touching completed media or similarly named foreign files.
- Finished stream termination uses a per-stream relay rather than retaining finished tokens. A late termination callback cannot affect a later job instance.

### RED Evidence

Before the implementation, the expanded deterministic `DownloadRunnerTests` suite failed on retry-analysis cancellation, consumer cancellation during reanalysis, resolved output-directory arguments, immediate cleanup/scope release, ownership replacement, and format fragment cleanup. A focused run of `testCancelStopsTrackedReanalysisBeforeReturning` also failed because `cancel(jobID:)` returned before scope release.

### Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DownloadRunnerTests`: 20 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-build --filter DownloadRunnerTests`: 19 tests, 0 failures (two repeat runs before the final idempotence regression was added).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-build --filter ProgressParserTests`: 13 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-build --filter OutputNameAllocatorTests`: 18 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 102 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/ytdp-task7-fix-round-1-concurrency -Xswiftc -strict-concurrency=complete`: 102 tests, 0 failures.
- `git diff --check`: clean.

### Remaining Concern

- Ownership verification is cooperative: processes using the allocator lock cannot interleave marker replacement and cleanup, while an unrelated external writer that bypasses the lock remains outside that coordination contract.
- One full-suite attempt exposed the pre-existing fixed-delay persistence test `testNonFlushSavesCoalesceToLatestSnapshot`; it passed in isolation and on the final ordinary and strict-concurrency full-suite runs. No unrelated persistence code was changed.
