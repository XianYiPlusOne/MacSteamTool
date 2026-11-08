#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET="${FLUENT_DOTNET:-$ROOT_DIR/work/dotnet/dotnet}"
if [[ ! -x "$DOTNET" ]]; then
  if command -v dotnet >/dev/null; then DOTNET="$(command -v dotnet)";
  else echo 'Install .NET SDK 8 or set FLUENT_DOTNET to its executable.' >&2; exit 1; fi
fi
"$DOTNET" publish "$ROOT_DIR/Engine/FluentSteamEngine" -p:RestoreLockedMode=true -c Release -r osx-arm64 --self-contained true -o "$ROOT_DIR/work/engine-publish"

"$DOTNET" publish "$ROOT_DIR/Engine/SteamlessBridge" -p:RestoreLockedMode=true -c Release -r win-x86 --self-contained true -o "$ROOT_DIR/work/steamless-bridge-publish"
