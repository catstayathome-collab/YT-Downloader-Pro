#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools"

for tool in ffmpeg ffprobe qjs yt-dlp_macos; do
  path="$TOOLS_DIR/$tool"
  if [[ ! -x "$path" ]]; then
    echo "Missing executable tool: $path" >&2
    exit 1
  fi
done

"$TOOLS_DIR/ffmpeg" -version >/dev/null
"$TOOLS_DIR/ffprobe" -version >/dev/null
qjs_output=$("$TOOLS_DIR/qjs" --help 2>&1 || true)
if [[ "$qjs_output" != *"QuickJS version"* ]]; then
  echo "qjs could not report its QuickJS version." >&2
  exit 1
fi

if ! "$TOOLS_DIR/yt-dlp_macos" --version >/dev/null; then
  echo "yt-dlp_macos could not run in this environment. This can happen inside restricted sandboxes; verify outside Codex before release." >&2
fi

file "$TOOLS_DIR/ffmpeg" "$TOOLS_DIR/ffprobe" "$TOOLS_DIR/qjs" "$TOOLS_DIR/yt-dlp_macos"
