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

## LAME

- Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- Version: 3.100
- License: GNU Lesser General Public License, version 2
- Purpose: statically linked into FFmpeg to provide the `libmp3lame` MP3 encoder.
- License text: `tools/licenses/LAME-LGPL-2.0.txt`
