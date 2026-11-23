#!/usr/bin/env bash
# Prepare a pinned, disposable steamplay-mac validation environment. No install.sh,
# Steam modifications, commercial CrossOver files, or global runtime registration.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_DIR="$ROOT_DIR/work/steamplay-validation"
UPSTREAM_DIR="$TASK_DIR/upstream"
REVISION=e350a87013fcbd4c81c33b59e8081f943b271955
BRIDGE_REVISION=df2f23a71bd42151e9aec923b1a01e50efcb8505
ASSET=steamplay-mac-2026.10.13-e350a87.dmg
ASSET_SHA=4d2446faa89f8c72838ca419df5b76d76a8d9ac52bea11cb47dd731ea83f85a8
if command -v brew >/dev/null 2>&1; then
  brew_prefix="$(brew --prefix)"
  export PATH="$brew_prefix/opt/curl/bin:$brew_prefix/bin:$PATH"
fi
mkdir -p "$TASK_DIR"
for tool in git curl python3 x86_64-w64-mingw32-gcc; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
arch -x86_64 /usr/bin/true || { echo 'Rosetta 2 is required' >&2; exit 1; }

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
    git clone --depth 1 --branch v2026.10.13 https://github.com/Drustburn/steamplay-mac.git "$UPSTREAM_DIR"
fi
[[ "$(git -C "$UPSTREAM_DIR" rev-parse HEAD)" == "$REVISION" ]] || { echo 'Unexpected upstream revision' >&2; exit 1; }
git -C "$UPSTREAM_DIR" submodule update --init --depth 1 notproton
[[ "$(git -C "$UPSTREAM_DIR/notproton" rev-parse HEAD)" == "$BRIDGE_REVISION" ]] || { echo 'Unexpected bridge revision' >&2; exit 1; }
git -C "$UPSTREAM_DIR" diff --quiet -- scripts
git -C "$UPSTREAM_DIR/notproton" diff --quiet -- app/Sources/NotProtonApp/Resources/valve-packages.manifest

if [[ ! -f "$TASK_DIR/$ASSET" ]]; then
    curl --fail --location --retry 3 --retry-all-errors --connect-timeout 20 \
        "https://github.com/Drustburn/steamplay-mac/releases/download/v2026.10.13/$ASSET" \
        -o "$TASK_DIR/$ASSET.part"
    mv "$TASK_DIR/$ASSET.part" "$TASK_DIR/$ASSET"
fi
printf '%s  %s\n' "$ASSET_SHA" "$TASK_DIR/$ASSET" | shasum -a 256 -c -

MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$TASK_DIR/mount" >/dev/null; fi
}
trap cleanup EXIT
if [[ ! -d "$TASK_DIR/runner" ]]; then
    mkdir -p "$TASK_DIR/mount"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$TASK_DIR/mount" "$TASK_DIR/$ASSET"
    MOUNTED=1
    ditto "$TASK_DIR/mount/Install steamplay-mac.app/Contents/Resources/payload/dist/runners/selfbuilt-cx26.3-r2" \
        "$TASK_DIR/runner"
    cleanup
    MOUNTED=0
fi

# Upstream fetchers verify every selected Valve file and the GPTK archive against
# their pinned hashes. Components remain in work/, outside the shipped application.
if [[ ! -f "$TASK_DIR/runner/lib/external/libd3dshared.dylib" ]]; then
    "$UPSTREAM_DIR/scripts/add-d3dmetal.sh" "$TASK_DIR/runner"
fi
"$UPSTREAM_DIR/scripts/fetch-valve-bridge.sh"
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra "$ROOT_DIR/Native/SteamPlayValidation/probe.c" \
    -o "$TASK_DIR/probe.exe" -ld3d11 -ld3d12 -ldxgi -lole32 -luuid
"$TASK_DIR/runner/bin/wine" --version
echo 'Prepared. Graphics: python3 script/validate_steamplay.py --only graphics'
echo 'Steam: add --steam-api /absolute/path/to/steam_api64.dll --app-id APPID'
