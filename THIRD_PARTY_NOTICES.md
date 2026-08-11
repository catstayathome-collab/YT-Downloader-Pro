# Third-Party Notices

This project bundles command-line tools used by YT Downloader Pro.

## yt-dlp

- Source: https://github.com/yt-dlp/yt-dlp
- Bundled helper: `tools/yt-dlp_macos`
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

## FFmpeg and FFprobe

- Source package used for 1.8.4: `ffmpeg-ffprobe-static` from https://github.com/descriptinc/ffmpeg-ffprobe-static
- Bundled release assets: `ffmpeg-darwin-arm64` and `ffprobe-darwin-arm64`
- Bundled helpers: `tools/ffmpeg`, `tools/ffprobe`
- FFmpeg license terms depend on the build configuration. The bundled FFmpeg build reports GPL-enabled and nonfree configuration.

Before public distribution, review all bundled binary licenses and include the complete required notices for the exact release artifacts shipped.
