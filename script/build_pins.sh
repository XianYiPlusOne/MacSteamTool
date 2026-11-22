#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION=5dfc8546954ce3b3198132ab13fddb89ee92cdd7
DOBBY_SOURCE="$ROOT_DIR/work/dobby"
if [[ ! -d "$DOBBY_SOURCE/.git" ]]; then git clone https://github.com/jmpews/Dobby.git "$DOBBY_SOURCE"; fi
if [[ "$(git -C "$DOBBY_SOURCE" rev-parse HEAD)" != "$REVISION" ]]; then
  git -C "$DOBBY_SOURCE" fetch --depth 1 origin "$REVISION"
  git -C "$DOBBY_SOURCE" checkout --detach "$REVISION"
fi
BUILD_ROOT="$ROOT_DIR/work/pins-build"
mkdir -p "$BUILD_ROOT"

# Build the actual ManifestPins implementation for each macOS architecture.
# The old flow built ARM64 once and added an x86_64 no-op bootstrap slice;
# that made a universal file, but Intel Steam never received the hook.
for arch in arm64 x86_64; do
  cmake -S "$ROOT_DIR/Native/ManifestPins" -B "$BUILD_ROOT/$arch" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DDOBBY_SOURCE="$DOBBY_SOURCE"
  cmake --build "$BUILD_ROOT/$arch" -j 6
done

lipo -create "$BUILD_ROOT/arm64/fluent_manifest.dylib" \
  "$BUILD_ROOT/x86_64/fluent_manifest.dylib" \
  -output "$BUILD_ROOT/fluent_manifest.dylib"
codesign --force --sign - "$BUILD_ROOT/fluent_manifest.dylib"

if [[ -f "$BUILD_ROOT/arm64/FluentManifestProbe" && -f "$BUILD_ROOT/x86_64/FluentManifestProbe" ]]; then
  lipo -create "$BUILD_ROOT/arm64/FluentManifestProbe" \
    "$BUILD_ROOT/x86_64/FluentManifestProbe" \
    -output "$BUILD_ROOT/FluentManifestProbe"
  codesign --force --sign - "$BUILD_ROOT/FluentManifestProbe"
fi
