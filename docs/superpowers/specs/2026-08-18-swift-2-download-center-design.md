# YT Downloader Pro Swift 2.0 Download Center Design

## 1. Summary

YT Downloader Pro 2.0 is a native macOS download center built with Swift and SwiftUI. It replaces the single-download Python/Tkinter macOS interface with a persistent, card-based, multi-download experience while preserving the stable behavior and user-facing features of the latest Python release.

The product lines remain intentionally separate:

- macOS uses Swift/SwiftUI and follows the `2.x` version line.
- Windows remains Python/Tkinter and follows the `1.8.x` version line.
- Each platform uses a separate update manifest and platform-specific release tags.

The initial Swift 2.0 release targets macOS 13 Ventura or later and supports both Intel and Apple Silicon Macs. It is distributed outside the Mac App Store. Development begins with an unsigned internal build, followed by Developer ID signing, notarization, DMG packaging, and a GitHub Release after real-device verification.

## 2. Goals

- Provide a native, responsive macOS interface with white surfaces, a status sidebar, and persistent download cards.
- Support multiple concurrent downloads with a user-adjustable limit from 1 to 10 and a default of 5.
- Preserve the latest stable Python release behavior for format selection, MP4/MP3 output, subtitles, thumbnails, cookies, output folders, duplicate filenames, pause/resume, cancel, retry, diagnostics, and update checks.
- Bundle one canonical toolchain inside the app and never require Homebrew.
- Keep queued, active, completed, cancelled, and failed work across app launches until the user clears the records.
- Present localized, actionable errors instead of raw `yt-dlp` or FFmpeg output.
- Isolate macOS 2.x releases and updates from the Windows 1.8.x release line.

## 3. Non-Goals For 2.0.0

- Mac App Store distribution.
- A background daemon that continues downloading after the app quits.
- Cloud synchronization of queues or history.
- Remote download control.
- Payment, licensing, or commercial account management.
- Automatic acquisition or storage of PO Tokens.
- Replacing `yt-dlp`, FFmpeg, or QuickJS with custom media extraction engines.

## 4. Source Strategy

Development starts from the latest stable `main` branch in a new `codex/` branch and isolated Git worktree. The existing `develop/v2.0-swift` branch is reference material only because it was based on an older Python release and does not include later download, toolchain, update, and error-handling fixes.

Useful model, persistence, process, and progress-parsing concepts may be ported after review. The old branch must not be merged wholesale.

## 5. Application Architecture

### 5.1 SwiftUI Presentation Layer

The presentation layer owns navigation, dialogs, cards, settings, localization, keyboard commands, accessibility labels, and user intent. Views never launch helper processes directly.

Primary view groups:

- `DownloadCenterView`: application shell, status sidebar, URL field, bulk actions, and filtered card list.
- `DownloadCardView`: one stable-size card for one `DownloadJob`.
- `MediaOptionsSheet`: central sheet shown after single-video analysis.
- `PlaylistSelectionSheet`: playlist expansion, selection, and shared defaults.
- `SettingsView`: concurrency, language, output folder, download defaults, cookies mode, diagnostics, and update settings.
- `ErrorDetailsView`: sanitized diagnostics for one failed job.

### 5.2 Download Store

`DownloadStore` is the observable source of truth consumed by SwiftUI. It exposes jobs, filters, counts, settings, and user commands. UI-visible mutations occur on the main actor.

The store delegates process scheduling and persistence to actors instead of sharing mutable global flags. No global progress, pause event, or cancellation flag is allowed.

### 5.3 Download Coordinator

`DownloadCoordinator` is an actor that owns the worker pool and enforces the concurrency limit.

- The valid limit is 1 through 10; the default is 5.
- Increasing the limit allows additional queued jobs to start immediately.
- Decreasing the limit never terminates active jobs. The new limit takes effect as active jobs finish.
- Each job has an independent task and process handle.
- A job may run only once at a time.
- Worker failures are isolated and cannot stop unrelated jobs.

### 5.4 Metadata Probe And Job Runner

`MetadataProbe` invokes bundled `yt-dlp_macos` to retrieve metadata and formats. `DownloadRunner` invokes it for downloads and emits structured events for status, progress, speed, bytes, estimated remaining time, output paths, post-processing stages, and sanitized diagnostic messages.

Process output is consumed asynchronously from stdout and stderr. Parsing is isolated from UI code and covered by fixture-based tests.

### 5.5 Toolchain

`Toolchain` resolves one canonical set of helpers under `Contents/Helpers/`:

- `yt-dlp_macos`
- `ffmpeg`
- `ffprobe`
- `qjs`

No default lookup is made in Homebrew, `/usr/local`, `/opt/homebrew`, or user PATH locations.

The helpers must support the architectures shipped by the app. Packaging validation checks executable permissions, code signatures, architecture slices, and actual execution. App startup and every new analysis session perform health checks using version commands rather than checking only for file existence.

Helper tools are signed before the outer app bundle. Packaging validation follows symbolic links and inode/realpath information to confirm there is one physical copy of each helper.

### 5.6 Persistence And Diagnostics

Persistent data lives under:

`~/Library/Application Support/YT Downloader Pro/`

Planned contents:

- `downloads.json`: versioned Codable snapshot of jobs and history.
- `Thumbnails/`: one cached thumbnail per job.
- `Diagnostics/diagnostics.jsonl`: sanitized diagnostic events with rotation.
- `State/`: temporary atomic-write and recovery files.

`PersistenceController` is an actor. It serializes writes, uses atomic replacement, keeps one recoverable previous snapshot, and debounces high-frequency progress updates. Status transitions and terminal events are flushed immediately.

Application preferences such as language, concurrency, and default options use `UserDefaults`. A user-selected output folder is represented by a persistent bookmark where required so the app can regain access after relaunch.

If persistence data is corrupt, the app preserves the damaged file for diagnosis, restores the last valid snapshot when available, and opens with a localized warning instead of crashing.

### 5.7 Updates

Update checks use separate manifests:

- macOS Swift: `updates/macos.json`
- Windows Python: `updates/windows.json`

The macOS manifest includes the latest version, minimum supported macOS version, release URL, download URL, SHA-256 checksum, publication time, and release notes summary. The macOS app never compares itself to the Windows version number.

Unauthenticated checks use the GitHub Contents API rather than a private raw URL. Automatic startup checks fail quietly on transient network errors. A manual check always reports success, up-to-date status, or an actionable error.

Release tags are platform-specific, for example:

- `macos-v2.0.0`
- `windows-v1.8.9`

## 6. Core Models

### 6.1 DownloadJob

`DownloadJob` contains:

- Stable UUID.
- Source URL and optional playlist identity.
- Title, duration, thumbnail cache path, and source metadata.
- Current `DownloadStatus`.
- Progress fraction, downloaded bytes, total bytes, speed, and estimated time remaining.
- Reserved output basename and final output URL.
- Immutable running options.
- Sanitized error information and retry count.
- Created, started, updated, and completed timestamps.

### 6.2 DownloadOptions

`DownloadOptions` contains:

- Output type: MP4 video or MP3 audio.
- Video quality: best or a selected resolution/format.
- Audio quality: best or a selected bitrate/format.
- Subtitle mode and language selection.
- Embed thumbnail and metadata options.
- Cookies mode selected by the user.
- Output directory bookmark and display path.

The default is the highest available video quality plus the highest available audio quality. MP3 mode selects the best available source audio before conversion.

### 6.3 DownloadStatus

Statuses are:

- `queued`
- `analyzing`
- `downloading`
- `paused`
- `merging`
- `completed`
- `failed`
- `cancelled`

Sidebar mapping:

- All: every retained job.
- Running: queued, analyzing, downloading, and merging.
- Stopped: paused and cancelled.
- Completed: completed.
- Failed: failed.

Cancelled jobs remain under Stopped until manually cleared.

### 6.4 DownloadError

Errors contain a stable category, localized summary key, optional recovery suggestion key, sanitized technical detail, tool exit code, and timestamp. Raw cookies, authorization headers, PO Tokens, and sensitive command arguments are never stored.

## 7. User Experience

### 7.1 Main Window

The approved layout uses:

- A near-white application background and opaque white download cards.
- A native macOS title bar with Settings access.
- A persistent left sidebar for All, Running, Stopped, Completed, and Failed.
- A permanent URL input at the top of the main pane.
- A visible Analyze button for pointer users.
- `Enter` in the URL field to analyze immediately without an extra add step.
- Bulk actions above the card list.

The visual hierarchy may learn from Parabolic but must not copy its branding or exact composition.

### 7.2 Analysis And Options

For a single video:

1. The user pastes a URL and presses Enter or Analyze.
2. The app validates the toolchain and analyzes the URL.
3. A central `MediaOptionsSheet` shows thumbnail, title, duration, available video quality, audio quality, output format, subtitles, thumbnail, metadata, cookies mode, and output folder.
4. Defaults select the highest available video and audio quality.
5. The user adds the configured job to the queue or cancels.

For a playlist:

1. The app expands the playlist into entries.
2. `PlaylistSelectionSheet` defaults to all entries selected.
3. The user may deselect individual entries.
4. Shared batch options apply to all selected entries.
5. Each resulting queued card may be edited individually before it starts.

Options are locked after a job starts. A paused job retains its original options to protect continuation compatibility.

### 7.3 Download Cards

Every card has stable dimensions and displays:

- Cached thumbnail.
- Title and selected format summary.
- Status.
- Progress bar.
- Downloaded and total bytes when known.
- Speed and remaining time when available.
- Status-appropriate icon actions with tooltips and accessibility names.

Actions by status:

- Queued: edit options, start now, cancel.
- Analyzing: pause, cancel.
- Downloading: pause, cancel.
- Paused: resume, cancel.
- Merging: cancel with confirmation; pause is unavailable.
- Completed: play, reveal in Finder, remove record.
- Failed: retry, view error details, remove record.
- Cancelled: re-add as a new clean job, remove record.

Removing a record never deletes a completed media file.

### 7.4 Bulk Actions

Available bulk actions are:

- Start all queued jobs.
- Pause all jobs that can be paused.
- Resume all paused jobs.
- Cancel queued and active jobs with confirmation.
- Clear completed records.

Bulk record clearing deletes matching cached thumbnails but never downloaded media.

### 7.5 Keyboard And Accessibility

- Enter analyzes the URL when the URL field is active.
- Command-V pastes normally. If focus is outside editable text and the clipboard contains a supported URL, the app may place it in the URL field without starting a download.
- Command-A selects all playlist entries only while the playlist selection sheet is active.
- Space pauses or resumes the selected eligible job.
- Delete removes the selected record after a clear confirmation that downloaded media is retained.
- Familiar symbol buttons use system or SF Symbols icons and provide localized tooltips.
- Keyboard focus is visible and VoiceOver labels describe action and state.
- Layout remains readable in Traditional Chinese, English, and Japanese without truncating critical controls.

## 8. Download Lifecycle

### 8.1 Queue And Start

Creating a job persists it before scheduling. The coordinator starts jobs while capacity exists. A user may request Start Now, but the coordinator still enforces the global concurrency ceiling.

### 8.2 Output Name Reservation

`OutputNameAllocator` is an actor that prevents concurrent jobs from selecting the same output path.

- Names are sanitized for macOS before reservation.
- Existing files and active reservations are both considered.
- Collisions produce `Title (1).ext`, `Title (2).ext`, and so on.
- A job's reserved basename is persisted so pause and relaunch reuse it.
- Reservations are released only after completion, full cancellation cleanup, or unrecoverable pre-download failure.

The allocator tracks only artifacts created by the app. Cleanup must never remove a pre-existing user file.

### 8.3 Pause And Resume

Pausing an analyzing job terminates the probe and marks it paused; resuming analyzes again. Pausing a downloading job requests graceful termination, retains compatible `.part` files, and marks the job paused. Resume starts a fresh bundled `yt-dlp` process with continuation enabled.

Merging cannot be paused through the card. The user may let it finish or cancel with confirmation. If the app must quit during merging, it interrupts the merge, removes only the incomplete merge artifact it created, preserves downloaded source streams, and marks the job paused. Resume restarts the post-processing stage.

### 8.4 Cancel

Cancel stops analysis, download, or post-processing and removes only tracked partial, temporary, and reservation artifacts belonging to that job. The retained record becomes `cancelled`. Re-add creates a new clean job with copied options.

### 8.5 Retry

Retry always analyzes the source again to refresh metadata and expiring media URLs. It reuses the original options and compatible `.part` files. If the selected format is no longer available, the app requests a new choice rather than silently downloading a materially different format.

### 8.6 Quit And Relaunch

Quitting stops accepting new work, requests graceful interruption of active jobs, persists them as paused, and preserves resumable artifacts. The app does not claim to continue in the background.

On relaunch, queued jobs remain queued and previously active jobs appear paused. The user explicitly chooses Resume All or resumes individual jobs.

## 9. YouTube Compatibility And Privacy

The initial download strategy matches the latest verified stable Python behavior, including its current JavaScript runtime and YouTube client handling. It removes unsafe options such as disabling certificate verification.

For retryable 403 or client failures:

1. Re-analyze to refresh format URLs.
2. Retry a bounded number of times with a reviewed client fallback sequence.
3. Preserve each attempt in sanitized diagnostics.
4. Stop and show an actionable localized error when the sequence is exhausted.

Fallback behavior is centralized and testable. Individual views and jobs may not invent their own client arguments.

Cookies are read only when the user chooses a browser cookies mode. Cookie contents are never copied into persistence or diagnostics. The app does not automatically obtain, store, or log PO Tokens. A future PO Token provider requires a separate reviewed design because it changes privacy, security, and maintenance requirements.

## 10. Error Handling

User-facing categories include:

- Invalid or unsupported URL.
- Video unavailable, private, removed, or region restricted.
- Sign-in, age, or membership requirement.
- Network unavailable or interrupted.
- YouTube client validation or HTTP 403 failure.
- Bundled helper missing, incompatible, or not executable.
- Output folder permission denied.
- Insufficient disk space.
- Download failed.
- FFmpeg merge or conversion failed.
- Persistence recovery warning.

The card shows a short localized summary and recovery action. Full sanitized details are available on demand. Raw helper output is not used as the primary alert text.

Diagnostics include timestamp, app version, macOS and architecture, tool versions, job stage, sanitized arguments, exit code, and relevant stderr excerpts. Log rotation limits retained size.

## 11. Localization

Swift 2.0 ships with:

- Traditional Chinese.
- English.
- Japanese.

The default follows the macOS language. Settings may override it. User-visible strings, error summaries, recovery suggestions, tool health messages, update messages, accessibility labels, and tooltips are localized through string catalogs.

## 12. Testing Strategy

### 12.1 Unit Tests

- Valid and invalid state transitions.
- Progress, speed, byte count, ETA, and post-processing parsing fixtures.
- Filename sanitization and numbered collisions.
- Concurrent output reservation.
- Format argument construction.
- Error categorization and sanitization.
- Version and update manifest comparison.
- Persistence migration, atomic recovery, and corrupt snapshot handling.

### 12.2 Coordinator Tests

- Limits of 1, 5, and 10 workers.
- Increasing and decreasing the limit while jobs are active.
- Start Now while at capacity.
- Independent pause, cancel, failure, and completion.
- App quit transition to paused.
- No duplicate execution of one job.

### 12.3 Integration Tests

Tests use fake helper executables for deterministic progress, failure, interruption, and post-processing output. Network-dependent YouTube checks are a separate manual smoke suite so normal automated tests do not depend on changing external behavior.

Manual smoke coverage includes:

- Single video and multiple pasted URLs.
- Playlist expansion and selection.
- MP4 and MP3.
- Highest quality defaults and specific quality choices.
- Subtitles, embedded thumbnail, and metadata.
- Pause/resume, cancel cleanup, and retry.
- Special characters and duplicate names.
- Custom output folders.
- Network loss, 403, unavailable media, cookies-required media, permission failure, disk-full simulation, and FFmpeg failure.

### 12.4 UI And Localization Tests

- Sidebar filters and counts.
- Cards in every status.
- Central options and playlist sheets.
- Bulk actions and keyboard commands.
- Traditional Chinese, English, and Japanese at supported window sizes.
- VoiceOver labels, tooltips, keyboard focus, and no overlapping text.

### 12.5 Packaging Verification

- macOS 13 or later on Apple Silicon and Intel hardware or equivalent CI runners.
- Universal app and helper architecture checks.
- Exactly one physical copy of each helper after resolving symbolic links.
- Executable permissions and real version commands from inside the built app.
- Helper-first and app-last signing order.
- Hardened runtime, notarization, Gatekeeper launch, and helper execution.
- DMG installation and first launch from Applications.
- macOS update manifest response, SHA-256, release URL, and tag alignment.

## 13. Release Acceptance Criteria

Swift 2.0.0 is ready for a signed public test release when:

- All automated unit, coordinator, integration, UI, and packaging tests pass.
- The approved white sidebar-and-card layout is implemented without overlap at supported window sizes.
- Single, batch, and playlist downloads work with the bundled toolchain.
- Concurrency 1 through 10 behaves as specified.
- Pause/resume, cancel cleanup, retry, duplicate naming, history restoration, thumbnails, and localization pass manual verification.
- Intel and Apple Silicon builds launch and execute every bundled helper.
- No raw cookies, PO Tokens, or sensitive arguments appear in persistence or diagnostics.
- The macOS update manifest points to the intended release and cannot trigger a Windows update.
- The Git tag, GitHub Release, packaged app version, checksum, and source commit all agree.

## 14. Delivery Order

1. Establish the Swift 2.0 package/project, models, storage, and fake-helper test harness.
2. Implement toolchain validation, metadata analysis, format mapping, and the central options sheet.
3. Implement the actor-based coordinator, job runner, progress parsing, pause/resume, cancel, and retry.
4. Implement output reservation, thumbnails, persistence recovery, history, and diagnostics.
5. Implement the approved SwiftUI shell, status sidebar, cards, bulk actions, keyboard commands, and localization.
6. Integrate the verified YouTube client strategy and bundled helpers.
7. Build and verify the unsigned internal app on real Macs.
8. Add signing, notarization, DMG packaging, split update manifest, and GitHub Release automation.
