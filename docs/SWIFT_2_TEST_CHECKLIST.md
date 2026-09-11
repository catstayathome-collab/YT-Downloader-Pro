# Swift 2.0 Test And Release Checklist

Use this checklist for `YT Downloader Pro 2.0.0` on macOS. Record the date,
machine, macOS version, app checksum, source commit, tester, and evidence link for
every run. `Not run` and `Blocked` are valid results; never convert them to Pass.

## Build Record

| Field | Value |
| --- | --- |
| Source commit | |
| App version | `2.0.0` |
| Bundle identifier | `com.tachouweng.ytdownloaderpro2` |
| ZIP SHA-256 | |
| Machine and architecture | |
| macOS version | |
| Tester and date | |

Result values: `Pass`, `Fail`, `Blocked`, or `Not run`.

## Automated Gates

| Gate | Command | Result | Evidence |
| --- | --- | --- | --- |
| Bundle verifier unit tests | `python3 -m unittest tests.test_swift_bundle -v` | | |
| Full pinned Python suite | `python3 -c 'import yaml' && python3 -m unittest discover -s tests -v` (after activating the project venv) | | |
| Full strict Swift suite | `cd swift-2.0 && swift test --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` | | |
| macOS 13 arm64 release build | `swift build --package-path swift-2.0 --configuration release --triple arm64-apple-macosx13.0 --disable-sandbox -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` | | |
| End-to-end internal bundle | `./scripts/build_swift_2.sh --version 2.0.0 --architectures arm64 --sbom-created 2026-08-27T00:00:00Z --unsigned-test` | | |
| Independent bundle verification | `python3 scripts/check_swift_bundle.py 'dist/YT Downloader Pro 2.app' --expected-version 2.0.0 --architectures arm64 --inventory tools/macos-helper-inventory.json` | | |
| Strict signature check | `codesign --verify --deep --strict --verbose=2 'dist/YT Downloader Pro 2.app'` | | |
| Universal request fails closed | `./scripts/build_swift_2.sh --version 2.0.0 --architectures universal --sbom-created 2026-08-27T00:00:00Z --unsigned-test` | | |

## Platform And Installation

| Scenario | Expected result | Result | Evidence |
| --- | --- | --- | --- |
| macOS 13 Ventura minimum | App launches and all four helper health checks complete | | |
| Apple Silicon | App and every helper execute natively; no Homebrew dependency | | |
| Intel | Blocked until one provenance-aligned universal four-helper toolchain exists | | |
| Copy to `/Applications` | App launches from its installed location | | |
| Gatekeeper first launch | Notarized public candidate opens without bypass instructions | | |
| DMG install | Drag-to-Applications flow preserves signature and helper execution | | |

## Download Workflows

| Scenario | Expected result | Result | Evidence |
| --- | --- | --- | --- |
| Single video | Analyze, configure, queue, download, merge, and reveal succeeds | | |
| Multiple URLs | Independent cards retain their own state and output | | |
| Playlist | Entries expand in source order; all available entries start selected | | |
| MP4 | Selected video and audio merge into MP4 | | |
| MP3 | Best selected audio converts to MP3 | | |
| Best quality | Defaults select highest available video and audio | | |
| Selected quality | Explicit format IDs are honored after analysis | | |
| Subtitles | None, sidecar download, and MP4 embed modes behave as selected | | |
| Embedded thumbnail | Supported image is embedded without corrupting output | | |
| Embedded metadata | Metadata toggle changes output as selected | | |
| Cookies opt-in | Chrome and Safari cookies are read only after explicit selection | | |
| Cookies off | No browser-cookie argument is passed | | |
| Custom output folder | Security-scoped permission survives relaunch | | |
| Duplicate names | Outputs use `Title (1)`, `Title (2)`, and never overwrite | | |

## Queue And Lifecycle

| Scenario | Expected result | Result | Evidence |
| --- | --- | --- | --- |
| Concurrency 1 | Exactly one job runs | | |
| Concurrency 5 | Up to five jobs run; this is the default | | |
| Concurrency 10 | Up to ten jobs run | | |
| Lower active limit | Existing jobs continue; replacement waits for the new limit | | |
| Pause and resume | Compatible partials and reserved basename remain; resume continues | | |
| Merge pause control | Pause is unavailable while merging | | |
| Quit recovery | Quit waits for interruption and flush; active work restores paused | | |
| Cancel cleanup | Only owned partial, temporary, and marker files are removed | | |
| Retry | Source is reanalyzed; missing saved format requests a new choice | | |
| Clear completed | History and cached thumbnail are removed; media remains | | |

## Failure And Recovery

| Scenario | Expected result | Result | Evidence |
| --- | --- | --- | --- |
| Offline | Localized network recovery appears; unrelated jobs remain intact | | |
| HTTP 403/client validation | One bounded reviewed fallback is attempted without cookies | | |
| Unavailable/private/region media | Stable localized category and recovery are shown | | |
| Disk full | Job fails with disk-space recovery and preserves unrelated files | | |
| FFmpeg failure | Merge/conversion category is shown; raw helper text is details only | | |
| Missing helper | Toolchain gate fails before analysis/download | | |
| Output permission revoked | User is asked to reselect the folder | | |
| Corrupt `downloads.json` | `State/downloads.previous` restores or a warning is shown | | |

## Localization And Visual QA

Inspect desktop and minimum `760 x 540` window layouts. Check cards, sidebar,
URL row, tabs, sheets, icon buttons, long error recovery, and keyboard focus.

| Locale | Main window and cards | Media options | Playlist sheet | Settings/errors | No overlap |
| --- | --- | --- | --- | --- | --- |
| English (`en`) | | | | | |
| Japanese (`ja`) | | | | | |
| Traditional Chinese (`zh-Hant`) | | | | | |

## Public Release Alignment

| Gate | Expected result | Result | Evidence |
| --- | --- | --- | --- |
| Developer ID signing | Helpers are signed first with hardened runtime; app is signed last | | |
| Notarization | Apple accepts the exact candidate and ticket is stapled | | |
| Gatekeeper | `spctl --assess --type execute --verbose=4` accepts installed app | | |
| DMG | DMG is signed/notarized, stapled, mounted, installed, and launched | | |
| Manifest checksum | `updates/macos.json` SHA-256 equals the published download | | |
| Version alignment | App plist, manifest, ZIP/DMG name, and release notes say `2.0.0` | | |
| Tag alignment | `macos-v2.0.0` resolves to the tested source commit | | |
| GitHub Release alignment | Tag, assets, checksums, source commit, and URLs agree | | |
| Windows isolation | Windows remains Python `1.8.x` and reads only `updates/windows.json` | | |

## Sign-Off

Release is blocked by any failed automated gate, missing helper slice for a
claimed architecture, signature/notarization failure, manifest mismatch, or
unrecorded required manual result.
