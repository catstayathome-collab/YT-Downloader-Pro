#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/tools"

for tool in ffmpeg ffprobe yt-dlp_macos; do
  path="$TOOLS_DIR/$tool"
  if [[ ! -x "$path" ]]; then
    echo "Missing executable tool: $path" >&2
    exit 1
  fi
done

"$TOOLS_DIR/ffmpeg" -version >/dev/null
"$TOOLS_DIR/ffprobe" -version >/dev/null

if ! "$TOOLS_DIR/yt-dlp_macos" --version >/dev/null; then
  echo "yt-dlp_macos could not run in this environment. This can happen inside restricted sandboxes; verify outside Codex before release." >&2
fi

file "$TOOLS_DIR/ffmpeg" "$TOOLS_DIR/ffprobe" "$TOOLS_DIR/yt-dlp_macos"
