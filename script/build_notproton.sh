#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT_DIR/Engine/NotProtonInstaller"
BIN_DIR="$(swift build --package-path "$ROOT_DIR/Engine/NotProtonInstaller" --show-bin-path)"
mkdir -p "$ROOT_DIR/work/macsteamtool-notproton-publish"
cp "$BIN_DIR/MacSteamToolNotProton" "$ROOT_DIR/work/macsteamtool-notproton-publish/MacSteamToolNotProton"
