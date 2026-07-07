#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/swift-2.0"
APP_NAME="YT Downloader Pro Swift"
APP_VERSION="2.0.0-alpha"
BUNDLE_ID="com.tachouweng.ytdownloaderpro.swift"
APP_PATH="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$SWIFT_DIR/.build/module-cache"

cd "$SWIFT_DIR"
CLANG_MODULE_CACHE_PATH="$SWIFT_DIR/.build/module-cache" swift build -c release --disable-sandbox
BIN_DIR="$(CLANG_MODULE_CACHE_PATH="$SWIFT_DIR/.build/module-cache" swift build -c release --show-bin-path --disable-sandbox)"
EXECUTABLE="$BIN_DIR/YTDownloaderPro2"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Missing Swift executable: $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"

cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/tools/yt-dlp_macos" "$ROOT_DIR/tools/ffmpeg" "$ROOT_DIR/tools/ffprobe" "$HELPERS_DIR/"
chmod 755 "$MACOS_DIR/$APP_NAME" "$HELPERS_DIR/yt-dlp_macos" "$HELPERS_DIR/ffmpeg" "$HELPERS_DIR/ffprobe"
xattr -cr "$APP_PATH" || true

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$HELPERS_DIR/yt-dlp_macos"
codesign --force --sign - "$HELPERS_DIR/ffmpeg"
codesign --force --sign - "$HELPERS_DIR/ffprobe"
codesign --force --sign - "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign - "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "Built: $APP_PATH"
