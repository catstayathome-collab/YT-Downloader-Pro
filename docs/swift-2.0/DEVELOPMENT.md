# Swift 2.0 Development

## Prerequisites

- macOS with full Xcode selected, not Command Line Tools alone.
- Swift 5.9 or later and an SDK that can target macOS 13.
- Python 3 for packaging tests and the bundle verifier.
- Repository helper files already present under `tools/`. Normal development
  and tests do not download helpers.

Confirm the local toolchain:

```bash
xcode-select -p
swift --version
xcrun xcstringstool help compile
python3 --version
```

Run commands from the repository root unless a command starts with `cd
swift-2.0`.

## Workspace Layout

```text
swift-2.0/
  Package.swift
  Sources/YTDownloaderPro2/
    App/        app lifecycle
    Models/     Codable and Sendable domain values
    Process/    Foundation Process boundary
    Services/   actors and focused value services
    Stores/     MainActor UI source of truth
    Views/      SwiftUI and presentation values
    Resources/  AppMetadata.json and Localizable.xcstrings
  Tests/YTDownloaderPro2Tests/
    Fixtures/   deterministic helper scripts and metadata JSON
    TestSupport/
scripts/
  build_swift_2.sh
  check_swift_bundle.py
tests/
  test_swift_bundle.py
tools/
  yt-dlp_macos ffmpeg ffprobe qjs
```

The package intentionally has no third-party Swift dependency. Do not add a
process, persistence, or JSON library when Foundation already owns that boundary.

## Helper Contract

The app resolves exactly these names in `Contents/Helpers`:

| Helper | Health command | Accepted result |
| --- | --- | --- |
| `yt-dlp_macos` | `--version` | exit 0 and a date version |
| `ffmpeg` | `-version` | exit 0 and an FFmpeg version |
| `ffprobe` | `-version` | exit 0 and the same FFmpeg family |
| `qjs` | `--help` | exit 0 or 1 plus `QuickJS version` |

Current repository slices are universal for `yt-dlp_macos` and arm64-only for
FFmpeg, FFprobe, and QuickJS. An arm64 build is supported. Universal and Intel
builds must remain blocked until all four helpers come from one reviewed,
provenance-aligned toolchain. Do not combine the old FFmpeg 8.1.2 Intel pair with
the current FFmpeg 9.0 arm64 pair.

## Build And Test

Focused Swift tests:

```bash
cd swift-2.0
swift test --filter ToolchainTests
swift test --filter DownloadRunnerTests
swift test --filter LocalizationTests
```

Complete strict Swift suite:

```bash
cd swift-2.0
swift test --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

### Local Authentication Skeleton

The implemented authentication surface is development-only and local-only. Run
the debug executable with `YTDP_AUTH_MODE=mock` to expose the synthetic Google
and Apple-labelled account controls. Leave the variable unset, or use any value
other than lowercase `mock`, to verify the normal disabled state with no
account controls.

The mock flow has no provider SDK, browser callback, network request, backend,
billing, entitlement delivery, or paid feature effect. Do not use it to claim
that Google, Apple, real accounts, production authentication, or external
submission is implemented. The full operating contract and scoped Keychain
cleanup details are in `AUTHENTICATION.md`.

Strict macOS 13 arm64 release compile:

```bash
swift build \
  --package-path swift-2.0 \
  --configuration release \
  --triple arm64-apple-macosx13.0 \
  --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
```

Packaging tests and Python regressions:

```bash
python3 -m unittest tests.test_swift_bundle -v
python3 -m unittest discover -s tests -v
```

If a pinned project environment is available, activate it, confirm that its
locked dependencies include PyYAML, and use that interpreter for complete
Python evidence:

```bash
python3 -c 'import yaml'
python3 -m unittest discover -s tests -v
```

Build the internal app only after focused tests are green:

```bash
./scripts/build_swift_2.sh \
  --version 2.0.0 \
  --architectures arm64 \
  --sbom-created 2026-08-27T00:00:00Z \
  --unsigned-test
```

This command runs the strict Swift suite again, release-builds for
`arm64-apple-macosx13.0`, assembles and ad-hoc signs the app, runs every helper,
writes `dist/swift-2.0-bundle-report.json`, and creates the internal ZIP.

## Localization Build

Preview the exact compiled output paths:

```bash
xcrun xcstringstool compile \
  swift-2.0/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings \
  --output-directory /private/tmp/ytdp-localizations \
  --language en --language ja --language zh-Hant \
  --serialization-format binary \
  --dry-run
```

The package copies the source catalog for locale override behavior. The app
bundle additionally contains compiled `Localizable.strings` in all three
`.lproj` directories.

## Fixtures And Test Doubles

- `Fixtures/video-analysis.json` and `playlist-analysis.json` cover typed yt-dlp
  decoding without network access.
- `Fixtures/fake-yt-dlp.sh` emits deterministic process phases and failures.
- `TestSupport/Fixtures.swift` contains shared model, runner, store, and temporary
  directory support.
- `tests/test_swift_bundle.py` creates regular-file fake app bundles and injects
  command output. It must prove an external symlink target is never executed.

Tests that mutate files use a temporary root. Automated tests must not contact
YouTube or rely on Homebrew/PATH helpers.

## Download Center Commands And Reservations

The compact toolbar below the URL field is a bulk task controller. Its commands
start queued jobs, pause active jobs, resume paused jobs, and cancel queued or
active jobs. A command must remain visibly disabled when no matching job exists;
automatic start does not make these commands redundant because restored or
manually paused queues still need recovery controls.

The trailing trash command clears terminal history (`completed`, `failed`, and
`cancelled`) plus owned thumbnail cache entries. It never stops active work and
never removes downloaded media. Failed and cancelled records must first release
their owned partial artifacts and reservation marker through
`DownloadCoordinator.cleanupDiscardedRecord`; if cleanup fails, retain that
record and log `history-cleanup` instead of creating a permanently orphaned
reservation. `DownloadStore` marks these IDs as being discarded before its
first cleanup suspension, invalidates existing retry generations, and rejects
new retry/edit/re-add requests until cleanup finishes. Recheck terminal status
after every suspension before deleting persistent state. Destructive
confirmations and automatic update notices share one
`DownloadCenterPresentedAlert` route. Do not attach competing `.alert`
modifiers to `DownloadCenterView`, because older SwiftUI releases may let the
later modifier shadow the confirmation alert.

Settings use the native `Settings` scene. macOS 14 and later open it through
`SettingsLink`; macOS 13 activates the standard Command-, application-menu item
before trying the legacy AppKit settings and preferences selectors. Keep the
menu shortcut working as the authoritative compatibility entry point.

`OutputNameAllocator` uses two distinct artifacts:

- `.<basename>.ytdp-reservation` is an ownership marker beside partial media. It
  is retained only while a job may resume and is removed after successful
  completion or cancellation.
- Advisory `.lock` files serialize competing allocators. Production stores them
  under `~/Library/Application Support/YT Downloader Pro/Reservation Locks/`,
  never beside downloaded media. The allocator opportunistically removes an
  orphaned legacy `.ytdp-reservation.lock` only when its matching ownership
  marker is absent and the legacy lock can be acquired without blocking.

Do not remove reservation markers from paused jobs: doing so can assign the same
basename to another concurrent job and break continuation of the partial file.

## Adding A Format Or Output Option

1. Extend the Codable model in `Models/DownloadOptions.swift`. Supply a decode
   default for old snapshots.
2. Centralize command mapping in `Services/YouTubeStrategy.swift`; do not build
   helper arguments in a view.
3. Update `MediaOptionsPresentation` and the applicable sheet.
4. Add strategy, presentation, model round-trip, and persisted migration tests.
5. Add localized labels in `Models/Localization.swift` and
   `Resources/Localizable.xcstrings` for `en`, `ja`, and `zh-Hant`.
6. Run strict focused and full suites.

## Adding An Error Category

1. Add the stable case to `DownloadFailure.Category` in
   `Models/DownloadError.swift`.
2. Add narrowly scoped classifier phrases with positive and adversarial negative
   fixtures. Ordinary titles and output paths must not classify as diagnostics.
3. Map the category to summary and recovery keys.
4. Add all three localized values and verify no raw helper text, cookie path,
   token, authorization value, or signed URL becomes user recovery copy.
5. Update `TROUBLESHOOTING.md` if the category introduces a new diagnosis layer.

## Adding A Localization Key

1. Add the raw key to `L10n.Key` in `Models/Localization.swift`.
2. Add the same key to `Localizable.xcstrings` with complete `en`, `ja`, and
   `zh-Hant` values and matching format placeholders.
3. Add the key to the explicit visible-key inventory when user-visible.
4. Run `swift test --filter LocalizationTests` and the strict full suite.
5. Build the app and inspect all three locales at the `760 x 540` minimum size.

## Codable Migration Rules

`downloads.json` currently uses envelope schema 1. New optional model fields
must decode absent values to behavior-compatible defaults. Never reinterpret a
stored format ID, cookie mode, reserved basename, output URL, or failure category
silently.

For a breaking shape change:

1. Increment `PersistenceController.schemaVersion`.
2. Decode every supported old envelope into an explicit migration value.
3. Preserve IDs, ownership markers, timestamps, output paths, and terminal media.
4. Keep unknown/newer schemas fail-closed and preserve the damaged file for
   diagnosis.
5. Test primary migration, previous-snapshot recovery, interrupted active jobs,
   and a failed migration before enabling writes.

Settings use Codable data under the `UserDefaults` key `app-settings`. Clamp
concurrency and normalize unsupported language overrides on both load and save.

## Debugging Workflow

Launch the SwiftPM development executable:

```bash
cd swift-2.0
swift run YTDownloaderPro2
```

This is useful for UI and model work, but it is not a packaging test because the
canonical helpers exist only in an assembled `.app`. For helper or signing
issues, build first and run:

```bash
python3 scripts/check_swift_bundle.py \
  'dist/YT Downloader Pro 2.app' \
  --expected-version 2.0.0 \
  --architectures arm64 \
  --inventory tools/macos-helper-inventory.json
codesign --verify --deep --strict --verbose=2 \
  'dist/YT Downloader Pro 2.app'
```

Diagnose from the outer layer inward: UI intent, Store state, coordinator event,
runner phase, process result, helper version/architecture, then filesystem
ownership. See `TROUBLESHOOTING.md` for exact user-safe diagnostics.
