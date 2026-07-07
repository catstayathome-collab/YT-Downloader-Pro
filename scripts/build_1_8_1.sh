#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="YT Downloader Pro"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
HELPERS_DIR="$APP_PATH/Contents/Helpers"

cd "$ROOT_DIR"
export PYINSTALLER_CONFIG_DIR="$ROOT_DIR/.pyinstaller-cache"

python3 -m PyInstaller \
  --noconfirm \
  --clean \
  --windowed \
  --onedir \
  --name "$APP_NAME" \
  --icon "$ROOT_DIR/AppIcon.icns" \
  --osx-bundle-identifier "com.tachouweng.ytdownloaderpro" \
  "$ROOT_DIR/YT_downloader_180.py"

mkdir -p "$HELPERS_DIR"
cp "$ROOT_DIR/tools/ffmpeg" "$ROOT_DIR/tools/ffprobe" "$HELPERS_DIR/"
chmod 755 "$HELPERS_DIR/ffmpeg" "$HELPERS_DIR/ffprobe"
xattr -cr "$HELPERS_DIR" || true

codesign --force --sign - "$HELPERS_DIR/ffmpeg"
codesign --force --sign - "$HELPERS_DIR/ffprobe"
codesign --force --deep --sign - "$APP_PATH"

"$ROOT_DIR/scripts/check_bundle_tools.py" "$APP_PATH"
