# Third-Party Notices

This project bundles command-line tools used by YT Downloader Pro.

## yt-dlp

- Source: https://github.com/yt-dlp/yt-dlp
- Bundled helper: `tools/yt-dlp_macos`
- Bundled Python package: `yt-dlp==2026.6.9`
- License details are provided by the upstream project.

## yt-dlp-ejs

- Source: https://github.com/yt-dlp/ejs
- Bundled Python package: `yt-dlp-ejs==0.8.0`
- License expression reported by the package: Unlicense AND MIT AND ISC
- Purpose: provides the JavaScript challenge solver files used by yt-dlp.

## QuickJS

- Source: https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
- Bundled helper: `tools/qjs`
- Version: 2026-06-04
- License: MIT
- Purpose: executes the bundled yt-dlp EJS challenge solver without requiring Homebrew or Deno.
- Build and checksum details: `tools/QUICKJS_BUILD_INFO.md`
- License text: `tools/licenses/QuickJS-MIT.txt`

## FFmpeg and FFprobe

- Source: https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz
- Bundled helpers: `tools/ffmpeg`, `tools/ffprobe`
- Version: 9.0
- License: GNU Lesser General Public License, version 2.1 or later
- Build: Apple Silicon arm64, statically linked FFmpeg libraries, macOS 11.0 deployment target
- Build and checksum details: `tools/FFMPEG_BUILD_INFO.md`
- License text: `tools/licenses/FFmpeg-LGPL-2.1.txt`

## BtbN FFmpeg and FFprobe (Windows x64 test build)

- Source distribution: BtbN FFmpeg-Builds
- Upstream: https://github.com/BtbN/FFmpeg-Builds
- Exact archive: https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-08-12-13-15/ffmpeg-N-126086-ge5ecfe8970-win64-lgpl.zip
- Version: `N-126086-ge5ecfe8970`
- SHA-256: `3fe180f31a12a1de60568cdcf72210a1d3f475f5f88719afdd6c7012e13f6d3e`
- License: `LGPL-2.1-or-later`
- License text: `tools/licenses/FFmpeg-LGPL-2.1.txt`
- Bundled Windows helpers: `Helpers/ffmpeg.exe`, `Helpers/ffprobe.exe`
- Archive member: `ffmpeg-N-126086-ge5ecfe8970-win64-lgpl/bin/ffmpeg.exe` -> `Helpers/ffmpeg.exe`
- Archive member: `ffmpeg-N-126086-ge5ecfe8970-win64-lgpl/bin/ffprobe.exe` -> `Helpers/ffprobe.exe`
- The Windows test build uses this pinned LGPL archive rather than the macOS arm64 helpers above.

## Deno (Windows x64 test build)

- Upstream: https://github.com/denoland/deno
- Exact archive: https://github.com/denoland/deno/releases/download/v2.8.1/deno-x86_64-pc-windows-msvc.zip
- Version: `2.8.1`
- SHA-256: `5fb5bac71f609fb91ec8960fb290885aadc27eeb22f07a8eca0c3db6be38b11a`
- License: `MIT`
- License text: `tools/licenses/Deno-MIT.txt`
- Bundled Windows helper: `Helpers/deno.exe`
- Archive member: `deno.exe` -> `Helpers/deno.exe`
- Purpose: executes the yt-dlp JavaScript challenge solver in the Windows x64 test build.

## LAME

- Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- Version: 3.100
- License: GNU Lesser General Public License, version 2
- Purpose: statically linked into FFmpeg to provide the `libmp3lame` MP3 encoder.
- License text: `tools/licenses/LAME-LGPL-2.0.txt`
