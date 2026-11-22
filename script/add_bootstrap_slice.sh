#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: add_bootstrap_slice.sh TARGET}"

# Kept as a compatibility entrypoint for old build recipes.  The previous
# implementation manufactured an x86_64 no-op slice, which made a universal
# file look compatible while Intel Steam received no hooks.  All supported
# targets are now produced by their architecture-aware build scripts.
case "$(basename "$TARGET")" in
  cloud_redirect.dylib) SOURCE="$ROOT_DIR/work/cloud-build/cloud_redirect.dylib" ;;
  fluent_manifest.dylib|manifest.dylib) SOURCE="$ROOT_DIR/work/pins-build/fluent_manifest.dylib" ;;
  macsteam.dylib|notproton.dylib) SOURCE="$ROOT_DIR/work/native-integration/$(basename "$TARGET")" ;;
  *) echo "unsupported target; run the architecture-aware build script first" >&2; exit 2 ;;
esac

[[ -f "$SOURCE" ]] || { echo "missing universal source $SOURCE" >&2; exit 1; }
for arch in arm64 x86_64; do lipo "$SOURCE" -verify_arch "$arch"; done
mkdir -p "$(dirname "$TARGET")"
cp "$SOURCE" "$TARGET"
codesign --force --sign - "$TARGET"
