# YT Downloader Pro

A professional YouTube Downloader for Mac, maintained by Ta-Chou Weng.

## Version map

- `v1.8.0-original`: original three-file snapshot before maintenance.
- `release/1.8.1`: stabilized Python/Tkinter build.
- `v1.8.2`: analysis fix for public videos without browser cookies.
- `v1.8.3`: remembers the user's last selected download folder.
- `v1.8.4`: replaces Intel-only FFmpeg helpers with Apple Silicon helpers and validates bundled tools before downloads.
- `develop/v2.0-swift`: native SwiftUI download center.

## 1.8.x toolchain

The Python app uses one bundled tool directory:

- Development: `tools/ffmpeg` and `tools/ffprobe`
- Packaged app: `YT Downloader Pro.app/Contents/Helpers/ffmpeg` and `ffprobe`

It no longer falls back to `/opt/homebrew/bin/ffmpeg`.

The bundled FFmpeg helpers are Apple Silicon executables. The app checks `ffmpeg -version` and `ffprobe -version` before downloads so users see a clear app error if the helper tools are missing, damaged, quarantined, or built for the wrong architecture.

## Build 1.8.4

```bash
./scripts/verify_tools.sh
./scripts/build_1_8_1.sh
./scripts/check_bundle_tools.py "dist/YT Downloader Pro.app"
```
