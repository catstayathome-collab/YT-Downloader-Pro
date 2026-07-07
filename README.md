# YT Downloader Pro

macOS YouTube downloader maintained by Ta-Chou Weng.

## Version map

- `v1.8.0-original`: original three-file snapshot before maintenance.
- `release/1.8.1`: stabilized Python/Tkinter build.
- `v1.8.2`: analysis fix for public videos without browser cookies.
- `v1.8.3`: remembers the user's last selected download folder.
- `develop/v2.0-swift`: native SwiftUI download center.

## 1.8.1 toolchain

The Python app uses one bundled tool directory:

- Development: `tools/ffmpeg` and `tools/ffprobe`
- Packaged app: `YT Downloader Pro.app/Contents/Helpers/ffmpeg` and `ffprobe`

It no longer falls back to `/opt/homebrew/bin/ffmpeg`.

Note: the currently bundled static FFmpeg helpers are Intel binaries. Homebrew's Apple Silicon FFmpeg is not copied into the app because it depends on Homebrew dynamic libraries under `/opt/homebrew`. Replace the bundled helpers with arm64 or universal static builds before broad Apple Silicon distribution.

## Build 1.8.1

```bash
./scripts/verify_tools.sh
./scripts/build_1_8_1.sh
./scripts/check_bundle_tools.py "dist/YT Downloader Pro.app"
```
