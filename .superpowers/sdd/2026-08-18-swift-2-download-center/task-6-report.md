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

## Fix Round 1: Format-Qualified Artifacts And Cooperative Marker Locks

### RED

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`

The expanded focused suite failed before implementation because `OutputNameAllocator(lockAcquiredHook:)` did not exist. This hook provides deterministic control after the allocator takes a candidate advisory lock, so the release race can be exercised without timing guesses.

### GREEN

- Candidate collision detection now enumerates the destination directory and treats only an exact basename or the `basename + "."` boundary as a collision. This includes yt-dlp format-qualified media and resume artifacts such as `Title.f137.mp4`, `.part`, `.ytdl`, and `.part-Frag123`, without treating `Title2` as `Title`.
- Every candidate has a persistent `.<basename>.ytdp-reservation.lock` file. Darwin `flock(LOCK_EX)` spans the reservation recheck/marker claim and the release ownership recheck/delete. Actor isolation remains in place for one allocator.
- The deterministic release test pauses after the cooperative lock is held, verifies a second nonblocking lock attempt is rejected, substitutes a foreign marker, then resumes and confirms the foreign marker remains.
- Extension names must be nonempty, contain no unsafe or control scalar, and fit within 64 UTF-8 bytes. Filename budgeting now accounts for the final extension, numbered suffix, marker, and lock filename; invalid extensions produce a stable sanitized `DownloadFailure`.

### Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputNameAllocatorTests`: 18 tests, 0 failures (run 1 of 10).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip-build --filter OutputNameAllocatorTests`: 18 tests, 0 failures (runs 2-10 of 10 consecutive runs).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 82 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -Xswiftc -strict-concurrency=complete`: 82 tests, 0 failures.
- `git diff --check`: clean.

### Commit

`fix(swift): harden output reservation locking`

### Concerns

- Advisory `flock` coordination protects cooperating allocator processes. A process that deliberately ignores the lock can still replace a marker; release rechecks the UUID while holding the lock and therefore never removes a replacement it observes, but no portable filesystem primitive makes an arbitrary noncooperating writer transactional with delete.
