#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
for cpu in arm64 x86_64; do
  triple="$cpu-apple-macosx15.0"
  flags=(--package-path "$ROOT_DIR/Engine/NotProtonInstaller"
         --scratch-path "$ROOT_DIR/work/notproton-build-$cpu" -c "$CONFIGURATION"
         --triple "$triple" -Xswiftc -target -Xswiftc "$triple")
  swift build "${flags[@]}" --product MacSteamToolNotProton
  BIN_DIR="$(swift build "${flags[@]}" --show-bin-path)"
  cp "$BIN_DIR/MacSteamToolNotProton" "$stage/$cpu"
done
lipo -create "$stage/arm64" "$stage/x86_64" -output "$stage/MacSteamToolNotProton"
for cpu in arm64 x86_64; do lipo "$stage/MacSteamToolNotProton" -verify_arch "$cpu"; done
codesign --force --sign - "$stage/MacSteamToolNotProton"
codesign --verify --strict --all-architectures "$stage/MacSteamToolNotProton"
mkdir -p "$ROOT_DIR/work/macsteamtool-notproton-publish"
mv -f "$stage/MacSteamToolNotProton" "$ROOT_DIR/work/macsteamtool-notproton-publish/MacSteamToolNotProton"
