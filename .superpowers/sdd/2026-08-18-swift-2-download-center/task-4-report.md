# Task 4 Report: YouTube Strategy And Metadata Analysis

## Changed Files

- `swift-2.0/Package.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Models/MediaAnalysis.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/YouTubeStrategy.swift`
- `swift-2.0/Sources/YTDownloaderPro2/Services/MetadataProbe.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/TestSupport/Fixtures.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/YouTubeStrategyTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/MetadataProbeTests.swift`
- `swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/video-analysis.json`
- `swift-2.0/Tests/YTDownloaderPro2Tests/Fixtures/playlist-analysis.json`

## RED/GREEN Evidence

- RED: `swift test --filter YouTubeStrategyTests` and `swift test --filter MetadataProbeTests` failed before the production services existed, reporting missing `YouTubeStrategy` and `MetadataProbe` symbols.
- GREEN: `swift test --filter YouTubeStrategyTests` passed 6 tests after the centralized argument strategy was added.
- GREEN: `swift test --filter MetadataProbeTests` passed 8 tests after typed JSON decoding, sanitized failures, and bounded retry handling were added.
- Corrected-policy RED: the capability-aware tests failed because the original implementation had one global attempt count and used `android_vr` as its fallback.
- Corrected-policy GREEN: the strategy now chooses `tv` only for an uncookied second attempt. Browser-cookie modes remain on `web_embedded` and terminate predictably after the initial attempt.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter YouTubeStrategyTests`: 6 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MetadataProbeTests`: 8 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 50 tests, 0 failures.

## Capability Ruling

Attempt zero remains `web_embedded`, matching the stable Python 1.8.8 policy. `android_vr` is intentionally excluded as a generic fallback: the August 2026 yt-dlp report shows that its HTTPS formats require a GVS PO Token except for format 18. The only reviewed fallback is `tv`, and it is selected only when no browser cookies were requested. The implementation does not promise that `tv` will provide high-quality formats; the official guide documents SABR and DRM caveats. No PO Token acquisition, stored token, cookie header, TLS bypass, PATH lookup, or Homebrew lookup was added.

Sources: [yt-dlp PO Token Guide](https://github.com/yt-dlp/yt-dlp/wiki/Po-Token-Guide) and [yt-dlp issue #17348](https://github.com/yt-dlp/yt-dlp/issues/17348).

## Commit

`feat(swift): analyze videos and playlists safely`

## Concerns

- YouTube client behavior and PO Token enforcement are volatile. The explicit `tv` fallback should be re-reviewed with the bundled yt-dlp version before a release.
- `tv` is a bounded diagnostics/recovery attempt, not a guarantee of a selectable high-quality stream. A failed attempt stays in sanitized `DownloadFailure` categories and does not silently degrade the selected format.

## Fix Round 1

### Changes

- Removed `tv` as an automatic fallback. Attempt zero explicitly selects `web_embedded`; uncookied attempt one omits `--extractor-args`, delegating only to the bundled yt-dlp version's reviewed default client selection. Browser-cookie modes remain one `web_embedded` attempt.
- Added exact, deterministic download arguments for `ytdp:phase|downloading`, the unchanged Task 5 progress template, MP4 `ytdp:phase|merging`, MP3 `ytdp:phase|postprocessing`, and `after_move` final filepaths. The postprocess hook is not merge-specific in yt-dlp, so the output-kind-specific marker is a deliberate approximation; Task 5 retains its known merger-line fallback.
- Download arguments now use the passed `Toolchain` for both FFmpeg and QuickJS.
- Typed metadata filtering now accepts HLS formats with usable URLs, while consistently excluding DRM-marked or URL-less video and audio formats.

### RED/GREEN Evidence

- RED: `YouTubeStrategyTests` failed with `tv` extractor arguments, missing phase markers, and the strategy toolchain's QuickJS path.
- RED: `MetadataProbeTests` failed because HLS was omitted and DRM/URL-less formats were retained.
- GREEN: `YouTubeStrategyTests` passed 7 tests.
- GREEN: `MetadataProbeTests` passed 8 tests.

### Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter YouTubeStrategyTests`: 7 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MetadataProbeTests`: 8 tests, 0 failures.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 51 tests, 0 failures.
- Fresh complete-concurrency build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /private/tmp/ytdp-task4-concurrency -Xswiftc -strict-concurrency=complete`: 51 tests, 0 failures.

### Release Follow-Up

Task 15 must test the bundled yt-dlp default fallback on representative videos, because attempt one intentionally delegates client selection to that pinned bundled version. It must verify that the fallback neither introduces PO Token handling nor silently substitutes a materially different selected format.

### Commit

`fix(swift): harden download strategy and metadata formats`
