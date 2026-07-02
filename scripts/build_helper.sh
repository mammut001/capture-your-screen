#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project capture-your-screen.xcodeproj \
  -target capture-screen-helper \
  -configuration Release \
  SYMROOT="$BUILD_DIR" \
  build

HELPER="$BUILD_DIR/Release/capture-screen-helper"
if [[ ! -x "$HELPER" ]]; then
  echo "Helper binary not found at $HELPER" >&2
  exit 1
fi

"$HELPER" --self-test
echo "Built and self-tested: $HELPER"