#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/work/patch-probe-publish"
vendor="$root/Native/NotProtonCore/steam-shim"
mkdir -p "$out"
temp="$(mktemp -d "$out/.build.XXXXXX")"
trap 'rm -rf "$temp"' EXIT
x86_64-w64-mingw32-g++ -std=c++17 -Os -static -municode -s -ffunction-sections -fdata-sections \
    -Wl,--gc-sections,--no-insert-timestamp -I"$vendor" \
    "$root/Engine/PatchProbe/main.cpp" "$vendor/jsoncpp.cpp" -o "$temp/PatchProbe.exe"
mv -f "$temp/PatchProbe.exe" "$out/PatchProbe.exe"
