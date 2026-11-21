#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$ROOT_DIR/work/dobby/.git" ]]; then bash "$ROOT_DIR/script/build_pins.sh"; fi
[[ "$(git -C "$ROOT_DIR/work/dobby" rev-parse HEAD)" == "5dfc8546954ce3b3198132ab13fddb89ee92cdd7" ]]
cmake -S "$ROOT_DIR/Native/CloudRedirect" -B "$ROOT_DIR/work/cloud-build" -DCMAKE_BUILD_TYPE=Release -DDOBBY_SOURCE="$ROOT_DIR/work/dobby"
cmake --build "$ROOT_DIR/work/cloud-build" -j 6
bash "$ROOT_DIR/script/add_bootstrap_slice.sh" "$ROOT_DIR/work/cloud-build/cloud_redirect.dylib"
