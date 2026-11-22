# Intel compatibility callbacks (implementation checkpoint)

The installer/recovery helper has a real x86_64 build. Native Steam integration
is a separate workstream; this checkpoint does **not** establish end-to-end
Windows game support on Intel.

## Reviewed client and layout

Steam build 1794536281, steamclient x86_64 UUID
`543c930a432c36fb998842214bd9d93c`. The complete function hashes, sizes and
required resolved sites are recorded in `NotProtonCore/dylib/feats/intel_compat.c`.
The runtime validates architecture, UUID, function boundaries, full function
contents and unique resolved sites before applying the layout. Unknown versions
and changed function bodies are rejected; there is no ARM-layout fallback.

Reviewed fields: manager enabled `0x810`, Windows-only table `0x698`, compatibility
tool fields shifted by 8 bytes from offset `0x58` onward (stride `0x138`).
The OS-list site at `0x66cd29` executes before `TEST RAX,RAX`; the callback changes
zero RAX to one and preserves flags for the original instruction. R12 is the tool.
The local redirect site at `0x66ce14` takes its tool from RAX and changes the
appid at `0x68` to zero, selecting the original local-tool path using `0x60`.
Only these two named instruction sites can receive Intel prehooks.

## Reproduction

From the repository root, after building Dobby and native dependencies:

```sh
bash script/test_intel_compat.sh "$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
python3 script/build_native_integration.py
make -C Native/NotProtonCore compatcheck ARCH=arm64
```

The profile test loads the local library in an isolated process and installs no
hooks. It rejects mutations in every reviewed function, wrong UUIDs, missing or
duplicate sites, incorrect addresses and invalid section bounds.
The callback test executes production callbacks against synthetic tool structures
and Dobby instrumentation on test-owned assembly, including restoration.

On the Apple silicon development host, tests run as x86_64 under Rosetta. The
page-remapping backend changes bytes successfully, but Rosetta retains previously
translated instructions even after `sys_icache_invalidate`. The fixture therefore
refreshes its own isolated, single-threaded code page using `mprotect` between
executions. This is **test-only** and does not prove live Steam patching on Rosetta.
Production Intel compatibility binding rejects translated execution (and
unexpected translation-query errors); native Intel does not require Rosetta.

## Remaining integration work

No production NotProton x86_64 signature profile is published by this checkpoint.
The independent macSteam x86_64 profile must not be treated as a NotProton profile.
WebUI, launch and CEG still need separate Intel analysis; the steamclient Intel
installation branch only installs the compatibility group and bypasses their
ARM instruction probes. Other image-specific installers remain separate.
Before releasing full Intel support, complete the required profiles and remaining
runtime bindings, then validate runner selection, game launch, update and restore
on an actual Intel Mac. The generated app bundle has not been refreshed with this
experimental native work.
