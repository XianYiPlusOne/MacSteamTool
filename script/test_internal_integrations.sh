#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/work/internal-integration-tests"
clang -std=c17 -arch arm64 -fsanitize=address,undefined -Wno-unused-parameter \
  "$ROOT_DIR/Native/SteamIntegration/relaunch_test.c" -o "$ROOT_DIR/work/internal-integration-tests/relaunch"
"$ROOT_DIR/work/internal-integration-tests/relaunch"
python3 "$ROOT_DIR/script/test_notproton_routes.py"
python3 "$ROOT_DIR/script/test_depot_selection.py"
mkdir -p "$ROOT_DIR/work/internal-integration-tests/source/out"
rsync -a "$ROOT_DIR/Native/NotProtonCore/" "$ROOT_DIR/work/internal-integration-tests/source/"
make -C "$ROOT_DIR/work/internal-integration-tests/source" \
  prefixstate-check compatsvc-check defaults-check compatpage-check compatcheck \
  seedcheck buildcheck envcheck routecheck launchercheck bridgecheck
