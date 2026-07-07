#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/YT Downloader Pro Swift.app}"

test -x "$APP_PATH/Contents/MacOS/YT Downloader Pro Swift"
test -x "$APP_PATH/Contents/Helpers/yt-dlp_macos"
test -x "$APP_PATH/Contents/Helpers/ffmpeg"
test -x "$APP_PATH/Contents/Helpers/ffprobe"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
file "$APP_PATH/Contents/MacOS/YT Downloader Pro Swift" \
     "$APP_PATH/Contents/Helpers/yt-dlp_macos" \
     "$APP_PATH/Contents/Helpers/ffmpeg" \
     "$APP_PATH/Contents/Helpers/ffprobe"
