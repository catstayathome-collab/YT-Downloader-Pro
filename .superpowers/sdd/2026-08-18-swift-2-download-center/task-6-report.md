# Task 6 Report: Concurrency-Safe Output Naming

## Changed Files

- `swift-2.0/Sources/YTDownloaderPro2/Services/OutputNameAllocator.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/OutputNameAllocatorTests.swift`
- `.superpowers/sdd/2026-08-18-swift-2-download-center/task-6-report.md`

## TDD Evidence

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`

The focused suite failed before implementation because `OutputNameAllocator` did not exist. The compiler reported `cannot find 'OutputNameAllocator' in scope` at every reservation test call site.

### GREEN

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`

Passed: 12 tests, 0 failures. Coverage includes selected and numbered final-file collisions, partial and alternate-container collisions, one-actor and two-actor allocation races, Unicode-safe sanitization and truncation, stable fallback names, persisted same-job ownership, pause/relaunch ownership retention, owned terminal cleanup, foreign/malformed marker protection, and stable sanitized destination failures.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`: 12 tests, 0 failures (run 1 of 3).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`: 12 tests, 0 failures (run 2 of 3).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`: 12 tests, 0 failures (run 3 of 3).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 76 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete`: 76 tests, 0 failures.
- `git diff --check`: clean.

## Implementation Notes

- `OutputReservation.baseURL` is extensionless so Task 4's `"\\(basename).%(ext)s"` yt-dlp template owns the final selected extension.
- The actor checks existing media, yt-dlp `.part` and `.ytdl` artifacts, known merge/container alternatives, active in-memory reservations, and persisted markers before claiming a basename.
- Marker data contains exactly `UUID.uuidString`. `Data.WritingOptions.withoutOverwriting` is the exclusive cross-allocator/process claim; a failed claim retries the next numbered basename.
- Markers are named `.<basename>.ytdp-reservation`. The basename reserve leaves room for both the selected final filename and that marker, and title truncation iterates Swift `Character` values so Unicode grapheme clusters remain intact.
- `release(jobID:removeMarker:)` never touches media. It removes a marker only after decoding an identical UUID; `removeMarker: false` drops in-memory state while retaining ownership for pause/relaunch.
- Filesystem errors become stable `DownloadFailure(category: .unknown)` values with no filesystem path or raw POSIX detail.

## Commit

`feat(swift): reserve unique output names`

## Concerns

- Task 7 must persist the returned extensionless basename on `DownloadJob` before launch, retain markers on pause/relaunch, and request terminal marker removal only after its own partial-artifact cleanup. The existing `reservedOutputBasename` and Task 4 template already provide the required handoff.
