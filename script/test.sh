#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SWIFT_BIN="$(xcrun --find swiftc)"
TOOLCHAIN_ROOT="$(cd "$(dirname "$SWIFT_BIN")/../.." && pwd)"
PLUGIN="$TOOLCHAIN_ROOT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# Swift 6.4's standalone CLT has Testing but does not auto-discover its macro plugin.
if [[ -f "$PLUGIN" ]]; then
  swift test --disable-xctest --enable-swift-testing -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
else
  swift test --disable-xctest --enable-swift-testing "$@"
fi
