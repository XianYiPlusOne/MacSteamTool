#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$ROOT_DIR/work/dobby/.git" ]]; then bash "$ROOT_DIR/script/build_pins.sh"; fi
[[ "$(git -C "$ROOT_DIR/work/dobby" rev-parse HEAD)" == "5dfc8546954ce3b3198132ab13fddb89ee92cdd7" ]]

BUILD_ROOT="$ROOT_DIR/work/cloud-build"
mkdir -p "$BUILD_ROOT"
for arch in arm64 x86_64; do
  cmake -S "$ROOT_DIR/Native/CloudRedirect" -B "$BUILD_ROOT/$arch" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DDOBBY_SOURCE="$ROOT_DIR/work/dobby"
  cmake --build "$BUILD_ROOT/$arch" -j 6
done
lipo -create "$BUILD_ROOT/arm64/cloud_redirect.dylib" \
  "$BUILD_ROOT/x86_64/cloud_redirect.dylib" \
  -output "$BUILD_ROOT/cloud_redirect.dylib"
codesign --force --sign - "$BUILD_ROOT/cloud_redirect.dylib"
