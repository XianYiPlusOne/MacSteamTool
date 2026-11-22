#!/usr/bin/env bash
set -euo pipefail
: "${1:?usage: build.sh OUTPUT.exe}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
jsoncpp="$root/Native/NotProtonCore/steam-shim"
mkdir -p "$(dirname "$1")"
x86_64-w64-mingw32-g++ -std=c++17 -Os -static -municode -s -I"$jsoncpp" \
  "$root/Tests/GameStartupProbe/main.cpp" "$jsoncpp/jsoncpp.cpp" -o "$1"
