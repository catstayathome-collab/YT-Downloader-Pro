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
