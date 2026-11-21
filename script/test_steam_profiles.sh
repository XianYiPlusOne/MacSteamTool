#!/bin/bash
# Actual local Steam image, no hooks, IPC session, login or game-data writes.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
client="${1:?Usage: test_steam_profiles.sh CLIENT_DYLIB PROFILE_JSON}"
profile="${2:?Supply the matching reviewed macSteam profile}"
out="$root/work/steam-profile-tests"
mkdir -p "$out"
clang -arch arm64 -O2 -I"$root/Native/MacSteam/src" -I"$root/Native/MacSteam/vendor" \
  "$root/Native/SteamIntegration/profile_probe.c" \
  "$root"/Native/MacSteam/src/resolver/{resolver,sigdb,anchor,aob}.c \
  "$root/Native/MacSteam/src/core/macho.c" \
  "$root"/Native/MacSteam/src/util/{log,file,hex}.c \
  "$root/Native/MacSteam/vendor/cJSON.c" -framework CoreFoundation -framework CFNetwork \
  -o "$out/profile-probe"
"$out/profile-probe" "$client" "$profile"
