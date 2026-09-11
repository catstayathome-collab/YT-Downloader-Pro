#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/swift-2.0"
BUILD_ROOT="$ROOT_DIR/build/swift-2.0"
CLANG_MODULE_CACHE_PATH="$SWIFT_DIR/.build/clang-module-cache"
export CLANG_MODULE_CACHE_PATH
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="YT Downloader Pro 2"
APP_PATH="$DIST_DIR/$APP_NAME.app"
EXECUTABLE_NAME="$APP_NAME"
REPORT_PATH="$DIST_DIR/swift-2.0-bundle-report.json"
VERSION=""
ARCHITECTURE_ARGUMENT="arm64"
SIGNING_IDENTITY=""
TEAM_ID=""
SBOM_CREATED=""
BUILD_KIND=""
HELPERS=(yt-dlp_macos ffmpeg ffprobe qjs)
ARCHITECTURES=()

usage() {
  cat <<'EOF'
Usage: ./scripts/build_swift_2.sh --version VERSION [options]

Options:
  --architectures LIST       arm64, x86_64, universal, or comma-separated slices
                             (default: arm64)
  --unsigned-test            ad-hoc sign an internal-test app and ZIP
  --signing-identity NAME    sign with a Developer ID Application identity
  --team-id TEAMID           expected 10-character Apple Team ID (Developer ID only)
  --sbom-created TIMESTAMP   SPDX creation time in RFC3339 UTC form
  -h, --help                 show this help
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
    --version)
      (($# >= 2)) || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --architectures)
      (($# >= 2)) || fail "--architectures requires a value"
      ARCHITECTURE_ARGUMENT="$2"
      shift 2
      ;;
    --unsigned-test)
      [[ -z "$BUILD_KIND" ]] || fail "choose only one signing mode"
      BUILD_KIND="internal"
      SIGNING_IDENTITY="-"
      shift
      ;;
    --signing-identity)
      (($# >= 2)) || fail "--signing-identity requires a value"
      [[ -z "$BUILD_KIND" ]] || fail "choose only one signing mode"
      BUILD_KIND="developer-id"
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --team-id)
      (($# >= 2)) || fail "--team-id requires a value"
      TEAM_ID="$2"
      shift 2
      ;;
    --sbom-created)
      (($# >= 2)) || fail "--sbom-created requires a value"
      SBOM_CREATED="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version must contain three numeric components"
[[ -n "$BUILD_KIND" ]] || fail "--unsigned-test or --signing-identity is required"
[[ "$SBOM_CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
  fail "--sbom-created must be an RFC3339 UTC timestamp such as 2026-08-27T00:00:00Z"
python3 -c 'import datetime, sys; value = sys.argv[1]; parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ"); raise SystemExit(0 if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value else 1)' \
  "$SBOM_CREATED" 2>/dev/null || \
  fail "--sbom-created must be a real RFC3339 UTC date and time"
if [[ "$BUILD_KIND" == "developer-id" ]]; then
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
    fail "Developer ID builds require --team-id with 10 uppercase letters or digits"
else
  [[ -z "$TEAM_ID" ]] || fail "--team-id is valid only with --signing-identity"
fi

case "$ARCHITECTURE_ARGUMENT" in
  universal|arm64,x86_64|x86_64,arm64)
    ARCHITECTURES=(arm64 x86_64)
    ;;
  arm64)
    ARCHITECTURES=(arm64)
    ;;
  x86_64)
    ARCHITECTURES=(x86_64)
    ;;
  *)
    fail "unsupported architecture request: $ARCHITECTURE_ARGUMENT"
    ;;
esac

ARCHITECTURE_LABEL="$(IFS=-; printf '%s' "${ARCHITECTURES[*]}")"
ZIP_PATH="$DIST_DIR/YT-Downloader-Pro-$VERSION-macOS-$ARCHITECTURE_LABEL-internal.zip"
if [[ "$BUILD_KIND" == "developer-id" ]]; then
  ZIP_PATH="$DIST_DIR/YT-Downloader-Pro-$VERSION-macOS-$ARCHITECTURE_LABEL.zip"
fi

preflight_helper_architectures() {
  local helper helper_path available_architecture requested_architecture found
  for helper in "${HELPERS[@]}"; do
    helper_path="$ROOT_DIR/tools/$helper"
    [[ -f "$helper_path" && ! -L "$helper_path" && -x "$helper_path" ]] || \
      fail "required helper must be a regular executable: tools/$helper"
    available_architecture="$(/usr/bin/lipo -archs "$helper_path")" || \
      fail "could not inspect helper architecture: tools/$helper"
    for requested_architecture in "${ARCHITECTURES[@]}"; do
      found=false
      for architecture in $available_architecture; do
        if [[ "$architecture" == "$requested_architecture" ]]; then
          found=true
          break
        fi
      done
      if [[ "$found" != true ]]; then
        fail "cannot build $ARCHITECTURE_LABEL: tools/$helper lacks $requested_architecture; current ffmpeg/ffprobe/qjs are one provenance-aligned arm64 set, so do not mix old binaries or claim Intel support"
      fi
    done
  done
}

preflight_helper_architectures

mkdir -p "$CLANG_MODULE_CACHE_PATH"

printf 'Running strict Swift tests...\n'
swift test \
  --package-path "$SWIFT_DIR" \
  --disable-sandbox \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"
BINARIES=()

for architecture in "${ARCHITECTURES[@]}"; do
  scratch_path="$BUILD_ROOT/$architecture"
  triple="$architecture-apple-macosx13.0"
  printf 'Building SwiftPM release executable for %s...\n' "$architecture"
  swift build \
    --package-path "$SWIFT_DIR" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --triple "$triple" \
    --disable-sandbox \
    -Xswiftc -strict-concurrency=complete \
    -Xswiftc -warnings-as-errors
  bin_path="$(swift build \
    --package-path "$SWIFT_DIR" \
    --scratch-path "$scratch_path" \
    --configuration release \
    --triple "$triple" \
    --disable-sandbox \
    --show-bin-path)"
  binary_path="$bin_path/YTDownloaderPro2"
  [[ -f "$binary_path" && -x "$binary_path" ]] || fail "SwiftPM release executable is missing: $binary_path"
  BINARIES+=("$binary_path")
done

rm -rf "$APP_PATH" "$ZIP_PATH" "$REPORT_PATH"
MACOS_DIR="$APP_PATH/Contents/MacOS"
HELPERS_DIR="$APP_PATH/Contents/Helpers"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR/ThirdPartyLicenses"

if ((${#BINARIES[@]} == 1)); then
  /usr/bin/install -m 755 "${BINARIES[0]}" "$MACOS_DIR/$EXECUTABLE_NAME"
else
  /usr/bin/lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/$EXECUTABLE_NAME"
  chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
fi

for helper in "${HELPERS[@]}"; do
  /usr/bin/install -m 755 "$ROOT_DIR/tools/$helper" "$HELPERS_DIR/$helper"
done

/usr/bin/install -m 644 "$ROOT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
/usr/bin/install -m 644 "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
/usr/bin/install -m 644 "$ROOT_DIR/SOURCE_AVAILABILITY.md" "$RESOURCES_DIR/SOURCE_AVAILABILITY.md"
/usr/bin/install -m 644 \
  "$SWIFT_DIR/Sources/YTDownloaderPro2/Resources/AppMetadata.json" \
  "$RESOURCES_DIR/AppMetadata.json"
/usr/bin/install -m 644 \
  "$SWIFT_DIR/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings" \
  "$RESOURCES_DIR/Localizable.xcstrings"
for license_name in \
  FFmpeg-LGPL-2.1.txt \
  GPL-3.0-or-later.txt \
  LAME-LGPL-2.0.txt \
  QuickJS-MIT.txt \
  yt-dlp-THIRD_PARTY_LICENSES.txt \
  yt-dlp-Unlicense.txt; do
  /usr/bin/install -m 644 \
    "$ROOT_DIR/tools/licenses/$license_name" \
    "$RESOURCES_DIR/ThirdPartyLicenses/$license_name"
done

xcrun xcstringstool compile \
  "$SWIFT_DIR/Sources/YTDownloaderPro2/Resources/Localizable.xcstrings" \
  --output-directory "$RESOURCES_DIR" \
  --language "en" \
  --language "ja" \
  --language "zh-Hant" \
  --serialization-format binary

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>YT Downloader Pro 2</string>
  <key>CFBundleExecutable</key>
  <string>YT Downloader Pro 2</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundleIdentifier</key>
  <string>com.tachouweng.ytdownloaderpro2</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ja</string>
    <string>zh-Hant</string>
  </array>
  <key>CFBundleName</key>
  <string>YT Downloader Pro 2</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

find "$APP_PATH" -type d -exec chmod 755 {} +
find "$APP_PATH" -type f -exec chmod 644 {} +
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
for helper in "${HELPERS[@]}"; do
  chmod 755 "$HELPERS_DIR/$helper"
done

# Quarantine is removed from copied bundle files only; source helpers remain untouched.
find "$APP_PATH" -type f -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

for helper in "${HELPERS[@]}"; do
  helper_path="$HELPERS_DIR/$helper"
  if [[ "$BUILD_KIND" == "internal" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$helper_path"
  else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$helper_path"
  fi
done

python3 "$ROOT_DIR/scripts/generate_swift_sbom.py" \
  --inventory "$ROOT_DIR/tools/macos-helper-inventory.json" \
  --source-helper-root "$ROOT_DIR/tools" \
  --helper-root "$HELPERS_DIR" \
  --license-root "$ROOT_DIR/tools/licenses" \
  --app-version "$VERSION" \
  --created "$SBOM_CREATED" \
  --output "$RESOURCES_DIR/SBOM.spdx.json"
chmod 644 "$RESOURCES_DIR/SBOM.spdx.json"

if [[ "$BUILD_KIND" == "internal" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"
else
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_PATH"
fi

ARCHITECTURE_CSV="$(IFS=,; printf '%s' "${ARCHITECTURES[*]}")"
VERIFY_SIGNING_ARGUMENTS=(--signing-mode "$BUILD_KIND")
if [[ "$BUILD_KIND" == "developer-id" ]]; then
  VERIFY_SIGNING_ARGUMENTS+=(--expected-team-id "$TEAM_ID")
fi
python3 "$ROOT_DIR/scripts/check_swift_bundle.py" \
  "$APP_PATH" \
  --expected-version "$VERSION" \
  --architectures "$ARCHITECTURE_CSV" \
  --inventory "$ROOT_DIR/tools/macos-helper-inventory.json" \
  "${VERIFY_SIGNING_ARGUMENTS[@]}" \
  --report "$REPORT_PATH" \
  --archive "$ZIP_PATH"

printf 'App: %s\n' "$APP_PATH"
printf 'Internal ZIP: %s\n' "$ZIP_PATH"
printf 'Verification report: %s\n' "$REPORT_PATH"
