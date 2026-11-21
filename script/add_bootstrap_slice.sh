#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$1"
STAGE="$(mktemp -d "$(dirname "$TARGET")/.bootstrap-slice.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ARCHES="$(lipo -archs "$TARGET")"
if [[ "$ARCHES" == "arm64" ]]; then
  cp "$TARGET" "$STAGE/arm64.dylib"
else
  lipo "$TARGET" -thin arm64 -output "$STAGE/arm64.dylib"
fi
clang -arch x86_64 -mmacosx-version-min=15.0 -dynamiclib \
  -install_name "@loader_path/$(basename "$TARGET")" \
  "$ROOT_DIR/Native/BootstrapSupport/noop.c" -o "$STAGE/x86_64.dylib"
lipo -create "$STAGE/arm64.dylib" "$STAGE/x86_64.dylib" -output "$STAGE/universal.dylib"
codesign --force --sign - "$STAGE/universal.dylib"
mv "$STAGE/universal.dylib" "$TARGET"
