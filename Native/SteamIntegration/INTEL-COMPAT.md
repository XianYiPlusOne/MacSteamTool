# Intel installer and compatibility integration

The installer/recovery helper and native libraries contain real x86_64 builds.
Intel profiles are supplied for Steam build **1794536281**, steamclient UUID
`543c930a432c36fb998842214bd9d93c`. This is a version-scoped implementation, not
an assurance that arbitrary Steam versions or every Windows game work.

## Implemented contracts

NotProton schema 4 uses architecture, module UUID, LC_FUNCTION_STARTS boundaries
and full SHA-256 function hashes. There is no ARM-anchor or AOB fallback on Intel.
All 22 compatibility/WebUI entries must resolve before installation proceeds.
`script/build_intel_notproton_profile.py` reproduces the reviewed profile from the
matching local client; it is not an automatic update/discovery tool.

Compatibility fields: enabled `0x810`, Windows-only table `0x698`, tool fields
shifted by 8 bytes from baseline offset `0x58` onward, tool stride `0x138`.
The OS-list callback runs at `0x66cd29`, before TEST RAX,RAX; tool is R12.
The local redirect runs at `0x66ce14`, before MOV ESI,[RAX+0x68]; tool is RAX.
SetCompatToolMapping is `0x66c5ea` (the asynchronous wrapper), distinct from
InternalSpecifyCompatTool at `0x66b6fe`.

The Intel WebUI contract uses registry accessor `0x90732`, parser `0xb3ada8`,
lookup call `0x90c64`, stock TransportAuth factory `0x91498`, constructor
`0x914c2`, job handler `0x9153e`, and notifier `0x92d32`. The constructor installs
vtable `0x18039d8`, with 17 methods and handler slot 14. Runtime pointer checks
validate the stock template before cloning it. RegisterHandler returns a C++
**bool**, not int; only AL is defined on Intel. The protobuf string pointer uses
the ordinary Intel libc++ string layout, rather than ARM's alternate layout.
Both short and heap-backed names are tested against actual client messages.
RTTI code-pointer validation also uses the target architecture's alignment.

The existing shell-command launch import binding is architecture independent.
Intel does not enable the unreviewed CEG, non-Steam shortcut, VR argument-rewrite
or Cocoa termination-wrapper hooks. These optional feature gaps must not be
represented as full ARM feature parity. Compatibility registration and selection
for Steam Windows games use the implemented path.

## Verification

```sh
python3 script/build_native_integration.py
bash script/test_intel_compat.sh "$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
make -C Native/NotProtonCore compatcheck compatsvc-check ARCH=arm64
make -C Native/NotProtonCore compatsvc-check ARCH=x86_64 OUT_DIR=../../work/intel-compat-unit
swift test --filter 'NativeIntegrationTests|OneClickSetupTests'
bash script/build_and_run.sh --build
```

The first checks perform read-only client resolution and mutation-negative tests.
Actual Dobby callbacks run only on test-owned assembly. A separate process loads
the real client/runtime, verifies all 22 entries, rejects every changed function
hash, constructs/parses real Intel protobuf messages, and registers/verifies all
nine compatibility routes in its private registry. It does not install Steam
hooks, connect a Steam session, or write the user's Steam configuration.

The development host is Apple silicon. Rosetta caches translated instructions
across the code-page replacement backend, even after sys_icache_invalidate. The
owned, single-threaded assembly fixture refreshes its own mapping with mprotect;
production never applies that workaround to live Steam pages. Intel binding
rejects Rosetta-translated execution and unexpected translation-query errors.
Physical Intel installation/game-launch testing remains an external acceptance
requirement; successful Rosetta tests do not replace it.
