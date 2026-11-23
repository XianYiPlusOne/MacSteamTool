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

# This process links the real runtime, whose constructor ignores test executables.
# Only its private Steam registry is changed; no running Steam process is touched.
clang -arch x86_64 -mmacosx-version-min=15.0 -O1 -g -Wall -Wextra \
  -I"$ROOT_DIR/work/dobby/include" "$NP/tests/intel-runtime-profile.c" \
  "$ROOT_DIR/work/native-integration/x86_64/notproton.dylib" \
  -Wl,-rpath,"$ROOT_DIR/work/native-integration/x86_64" -o "$STAGE/runtime-profile"
/usr/bin/arch -x86_64 "$STAGE/runtime-profile" "$CLIENT" \
  "$ROOT_DIR/Native/NotProtonCore/signatures/macos.x86_64/1794536281.json"
