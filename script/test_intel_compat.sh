#!/usr/bin/env bash
# Only the read-only profile test loads Steam; instrumentation uses owned fixtures.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="${1:?Usage: test_intel_compat.sh CLIENT_DYLIB}"
mkdir -p "$ROOT_DIR/work/intel-compat-tests"
STAGE="$(mktemp -d "$ROOT_DIR/work/intel-compat-tests/run.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
NP="$ROOT_DIR/Native/NotProtonCore/dylib"
clang -arch x86_64 -mmacosx-version-min=15.0 -O1 -g -Wall -Wextra \
  "$NP/tests/intel-compat-profile.c" "$NP/feats/intel_compat.c" "$NP/core/macho.c" \
  -o "$STAGE/profile"
/usr/bin/arch -x86_64 "$STAGE/profile" "$CLIENT"
clang -arch x86_64 -mmacosx-version-min=15.0 -O1 -g -Wall -Wextra \
  -I"$ROOT_DIR/work/dobby/include" "$NP/tests/intel-compat-callbacks.c" \
  "$NP/tests/intel-compat-fixture.S" "$ROOT_DIR/work/pins-build/x86_64/dobby/libdobby.a" \
  -Wl,-dead_strip -lc++ -o "$STAGE/callbacks"
/usr/bin/arch -x86_64 "$STAGE/callbacks"
