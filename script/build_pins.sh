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
cmake -S "$ROOT_DIR/Native/ManifestPins" -B "$ROOT_DIR/work/pins-build" -DCMAKE_BUILD_TYPE=Release -DDOBBY_SOURCE="$DOBBY_SOURCE"
cmake --build "$ROOT_DIR/work/pins-build" -j 6
bash "$ROOT_DIR/script/add_bootstrap_slice.sh" "$ROOT_DIR/work/pins-build/fluent_manifest.dylib"
