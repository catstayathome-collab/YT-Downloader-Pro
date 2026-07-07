# Third-Party Notices

This project bundles command-line tools used by YT Downloader Pro.

## yt-dlp

- Source: https://github.com/yt-dlp/yt-dlp
- Bundled helper: `tools/yt-dlp_macos`
- License details are provided by the upstream project.

## FFmpeg and FFprobe

- Source package used for 1.8.4: `ffmpeg-ffprobe-static` from https://github.com/descriptinc/ffmpeg-ffprobe-static
- Bundled release assets: `ffmpeg-darwin-arm64` and `ffprobe-darwin-arm64`
- Bundled helpers: `tools/ffmpeg`, `tools/ffprobe`
- FFmpeg license terms depend on the build configuration. The bundled FFmpeg build reports GPL-enabled and nonfree configuration.

Before public distribution, review all bundled binary licenses and include the complete required notices for the exact release artifacts shipped.
