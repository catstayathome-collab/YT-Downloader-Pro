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
