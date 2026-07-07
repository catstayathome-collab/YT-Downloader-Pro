#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/swift-2.0"

mkdir -p "$SWIFT_DIR/.build/module-cache"

cd "$SWIFT_DIR"
CLANG_MODULE_CACHE_PATH="$SWIFT_DIR/.build/module-cache" swift build --disable-sandbox
