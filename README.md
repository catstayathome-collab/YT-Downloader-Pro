# YT Downloader Pro

macOS YouTube downloader maintained by Ta-Chou Weng.

## Version map

- `v1.8.0-original`: original three-file snapshot before maintenance.
- `release/1.8.1`: stabilized Python/Tkinter build.
- `develop/v2.0-swift`: native SwiftUI download center.

## 1.8.1 toolchain

The Python app uses one bundled tool directory:

- Development: `tools/ffmpeg` and `tools/ffprobe`
- Packaged app: `YT Downloader Pro.app/Contents/Helpers/ffmpeg` and `ffprobe`

It no longer falls back to `/opt/homebrew/bin/ffmpeg`.

## Build 1.8.1

```bash
./scripts/verify_tools.sh
./scripts/build_1_8_1.sh
./scripts/check_bundle_tools.py "dist/YT Downloader Pro.app"
```
