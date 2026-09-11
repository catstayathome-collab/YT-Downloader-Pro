# Swift 2.0 Troubleshooting

Diagnose one layer at a time. Preserve the first failing command and its complete
exit status. Do not replace helpers, delete state, or bypass signatures before
collecting evidence.

## Quick Layer Map

| Symptom | First layer | First check |
| --- | --- | --- |
| URL never opens options | Analysis | Toolchain health, then `MetadataProbe` classification |
| HTTP 403 after analysis | YouTube strategy | Reanalysis and bounded client fallback |
| Helper missing/incompatible | Bundle | `check_swift_bundle.py` and canonical paths |
| MP4/MP3 fails late | FFmpeg/post-processing | FFmpeg/FFprobe agreement and job diagnostics |
| Cannot save | Bookmark/permission | Reselect output folder and verify free space |
| Queue/history wrong after launch | Persistence | Primary then previous schema-1 snapshot |
| Wrong/missing language | Localization | Source catalog plus three compiled `.lproj` files |
| Update check fails | Update transport/manifest | Manual check, HTTPS endpoint, bounded schema |
| App will not open | Signing/Gatekeeper | strict codesign, notarization, `spctl` |

## Analysis Failures

Confirm the app contains one canonical helper set:

```bash
python3 scripts/check_swift_bundle.py \
  'dist/YT Downloader Pro 2.app' \
  --expected-version 2.0.0 \
  --architectures arm64 \
  --inventory tools/macos-helper-inventory.json
```

If the report is green, reproduce with the app's Analyze action and note whether
the failure is invalid URL, unavailable/private/region restricted, sign-in/age,
network, 403/client validation, or generic analysis. `MetadataProbe` uses typed
`--dump-single-json` output; malformed JSON is an analysis failure, not a UI
failure.

Do not add `--no-check-certificate`, a PATH helper, or an unreviewed YouTube
client. Cookies are a separate explicit opt-in test.

## Network And HTTP 403

Offline and DNS/TLS failures should classify as network problems. Restore
connectivity and analyze again. Check system date/time before suspecting the
media strategy.

For uncookied 403/client validation, the implementation tries the reviewed
`web_embedded` client, reanalyzes, and permits one bundled-default fallback.
Browser-cookie modes use one `web_embedded` attempt only. If the bounded sequence
fails, collect sanitized diagnostics; do not loop indefinitely or invent client
arguments per job.

Never request cookie files, browser profiles, authorization headers, signed media
URLs, or PO Tokens from a user.

## Helper Execution

Run only the copied app helpers:

```bash
'dist/YT Downloader Pro 2.app/Contents/Helpers/yt-dlp_macos' --version
'dist/YT Downloader Pro 2.app/Contents/Helpers/ffmpeg' -version
'dist/YT Downloader Pro 2.app/Contents/Helpers/ffprobe' -version
'dist/YT Downloader Pro 2.app/Contents/Helpers/qjs' --help
```

Expected current versions are yt-dlp `2026.07.04`, FFmpeg/FFprobe `9.0`, and
QuickJS `2026-06-04`. QuickJS may exit 1 for `--help`; it is healthy only when
the `QuickJS version` marker is present. All other health commands require exit
0.

Inspect slices and dependencies:

```bash
lipo -archs 'dist/YT Downloader Pro 2.app/Contents/Helpers/yt-dlp_macos'
lipo -archs 'dist/YT Downloader Pro 2.app/Contents/Helpers/ffmpeg'
otool -L 'dist/YT Downloader Pro 2.app/Contents/Helpers/ffmpeg'
```

The current internal app is arm64. A universal request failing on missing
x86_64 FFmpeg/FFprobe/QuickJS is correct behavior, not a build workaround.

## FFmpeg Merge Or Conversion

First verify FFmpeg and FFprobe report the same version and only system dynamic
dependencies. Then distinguish:

- Download failure before `merging`: source/format/network layer.
- MP4 failure during `merging`: FFmpeg merge or incompatible streams.
- MP3 failure during `postprocessing`: FFmpeg conversion, disk, or permission.
- Exit 0 without an owned final output: output verification failure.

Retry reanalyzes source formats. If a selected format disappeared, choose a new
format; do not silently substitute a materially different one. Keep source
partials until ownership-safe cleanup or a successful continuation decides them.

## Output Folder And Bookmarks

Output folders use security-scoped bookmarks. A stale, unreadable, or revoked
bookmark intentionally becomes `needsReselection`.

1. Open Settings or the options sheet.
2. Select the intended folder again.
3. Confirm it is writable and has enough free space.
4. Retry the job.

Do not edit bookmark bytes in `UserDefaults`. Do not grant broad disk access as
the first response. Duplicate output names are expected to reserve `Title (1)`,
`Title (2)`, and later names. Removing a history record never removes completed
media.

## Persistence Recovery

State lives at:

```text
~/Library/Application Support/YT Downloader Pro/downloads.json
~/Library/Application Support/YT Downloader Pro/State/downloads.previous
~/Library/Application Support/YT Downloader Pro/State/downloads.next
```

The loader prefers `downloads.json`, then the previous snapshot. Active states
restore as paused. If neither snapshot decodes as schema 1, the app must warn
rather than overwrite evidence silently.

Before manual repair:

```bash
cp -R "$HOME/Library/Application Support/YT Downloader Pro" \
  "$HOME/Desktop/YT Downloader Pro State Backup"
```

Do not delete the original until the backup has been inspected. `downloads.json`
contains source URLs and media titles, so treat it as user data and request it
only with consent after sanitization.

## Thumbnail Cache

Cached images are named by job UUID under:

```text
~/Library/Application Support/YT Downloader Pro/Thumbnails/
```

The cache accepts decoded JPEG, PNG, GIF, or WebP only and rejects symlinked
roots/leaves. A missing thumbnail does not block the media output. Clearing a
record may remove its cached thumbnail but not the downloaded media.

## Localization

Verify packaged resources:

```bash
find 'dist/YT Downloader Pro 2.app/Contents/Resources' \
  -path '*lproj/Localizable.strings' -print
plutil -p 'dist/YT Downloader Pro 2.app/Contents/Info.plist'
```

Required locales are `en`, `ja`, and `zh-Hant`, and the source
`Localizable.xcstrings` must also be present. Unsupported persisted language
values fall back to the system locale. A raw key on screen usually means a
missing catalog entry or placeholder mismatch; run:

```bash
cd swift-2.0
swift test --filter LocalizationTests
```

Inspect the minimum `760 x 540` window in all three locales after changing long
copy. Automated catalog completeness does not replace visual overlap testing.

## Update Checks

Swift 2 reads the GitHub Contents API representation of `updates/macos.json`
only. Automatic transient failures stay quiet; use the Settings manual check to
obtain an actionable result.

Validate the checked-in file without network access:

```bash
python3 -m json.tool updates/macos.json
```

The checker rejects the Windows platform, malformed SemVer, non-HTTPS or
credential-bearing URLs, non-lowercase SHA-256, invalid minimum macOS, wrong
redirect origin/path, oversized responses, and stale cancelled responses. Root
`version.txt` is legacy Python compatibility and is not a Swift repair path.

## Signing, Gatekeeper, And Notarization

Run the checks separately so the failing layer is visible:

```bash
codesign --verify --deep --strict --verbose=2 \
  'dist/YT Downloader Pro 2.app'
codesign -dv --verbose=4 'dist/YT Downloader Pro 2.app'
spctl --assess --type execute --verbose=4 \
  'dist/YT Downloader Pro 2.app'
xcrun stapler validate 'dist/YT Downloader Pro 2.app'
```

- codesign failure: bundle content changed after signing, nested helper signature
  is invalid, or nonstandard content exists outside `Contents`.
- codesign pass but `spctl` fail before public release: Developer ID,
  notarization, or ticket problem.
- notarization accepted but stapler fail: wrong artifact or ticket not available.
- copied app fails after ZIP/DMG install: verify the installed copy, not the build
  directory.

Never use `xattr -cr` as a public release fix and never remove quarantine from
repository helpers. The build script removes only the quarantine attribute from
copied bundle files before signing.

## Diagnostics Safe To Request

Primary sanitized logs:

```text
~/Library/Application Support/YT Downloader Pro/Diagnostics/diagnostics.jsonl
~/Library/Application Support/YT Downloader Pro/Diagnostics/diagnostics.1.jsonl
~/Library/Application Support/YT Downloader Pro/Diagnostics/diagnostics.2.jsonl
~/Library/Application Support/YT Downloader Pro/Diagnostics/diagnostics.3.jsonl
```

Packaging diagnostics:

```text
dist/swift-2.0-bundle-report.json
```

It is safe to request the relevant sanitized diagnostic lines, app version,
macOS version, Mac architecture, job stage, and bundle report after asking the
user to review them. Still instruct the user to remove unrelated URLs/titles.
Do not request cookies, browser profile data, authorization headers, PO Tokens,
signed media URLs, full home-directory listings, or raw `downloads.json` by
default.
