# YT Downloader Pro

A professional YouTube Downloader for Mac, maintained by Ta-Chou Weng.

## Version map

- `v1.8.0-original`: original three-file snapshot before maintenance.
- `release/1.8.1`: stabilized Python/Tkinter build.
- `v1.8.2`: analysis fix for public videos without browser cookies.
- `v1.8.3`: remembers the user's last selected download folder.
- `develop/v2.0-swift`: native SwiftUI download center.

## 1.8.x toolchain

The Python app uses one bundled tool directory:

- Development: `tools/ffmpeg` and `tools/ffprobe`
- Packaged app: `YT Downloader Pro.app/Contents/Helpers/ffmpeg` and `ffprobe`

It no longer falls back to `/opt/homebrew/bin/ffmpeg`.

Note: the currently bundled static FFmpeg helpers are Intel binaries. Homebrew's Apple Silicon FFmpeg is not copied into the app because it depends on Homebrew dynamic libraries under `/opt/homebrew`. Replace the bundled helpers with arm64 or universal static builds before broad Apple Silicon distribution.

## Build 1.8.3

```bash
./scripts/verify_tools.sh
./scripts/build_1_8_1.sh
./scripts/check_bundle_tools.py "dist/YT Downloader Pro.app"
```

## Build Swift 2.0 Preview

```bash
./scripts/build_swift_2_0.sh
./scripts/build_swift_2_0_app.sh
./scripts/check_swift_app.sh
```

## Swift 2.0 preview

The native download center skeleton lives in `swift-2.0/`.

```bash
./scripts/build_swift_2_0.sh
```
