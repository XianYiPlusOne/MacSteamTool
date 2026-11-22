# MacSteamTool Manifest extension

Independent macOS ARM64 implementation, distributed with MacSteamTool under AGPL-3.0. It does not bundle Steam or macSteam binaries.

- Hook engine: [Dobby](https://github.com/jmpews/Dobby), unmodified revision `5dfc8546954ce3b3198132ab13fddb89ee92cdd7`, Apache-2.0 (`Licenses/Dobby.txt`). Build script fetches that source and links it privately; Dobby exports are hidden to avoid interposition with macSteam's own instance.
- Manifest framing and metadata: [SteamKit DepotManifest](https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Types/DepotManifest.cs) and [content_manifest.proto](https://github.com/SteamDatabase/Protobufs/blob/master/steam/content_manifest.proto). CRC/framing/identity checks do **not** verify Valve's cryptographic signature.
- macSteam's YAML parser ignores unknown root sections. `FluentManifestPins` adds an app/depot/gid map; the Swift application updates it in the same backed-up transaction as the Lua and macSteam settings. The extension checks that each owner remains in `Apps`, loads only verified matching cached manifests, and hot reloads the effective map.

## Verified profile

Steam ARM64 build `1792618285`, Mach-O UUID `1D282616-B67E-30A6-B0AF-E4D5880610E7`. The loader validates this UUID, the text segment boundary and the original 32-byte prologue before installing a detour. Other builds and pre-existing detours are refused.

The depot selection helper at `steamclient + 0x5b0394` uses `(depotState*, depotsKeyValues*, branchName) -> bool`: depot ID at `+0`, output manifest GID at `+8`, output uncompressed disk size at `+16`. It reads `<depot>/manifests/<branch>/gid` and `size` using the real KeyValues API. This layout and return behavior were verified by calling the actual Steam function with a synthetic KeyValues tree in an independent process.

The extension calls the original function first, preserves failed metadata lookups, and changes only valid `public` branch selections whose depot is explicitly pinned. Manifest disk size comes from metadata field 5. Private and beta branches pass through. This does not synthesize depot ownership or supply request codes.

## Validation and limits

`script/test_manifest_native.py` loads the real Steam dylib without Steam IPC. It tests the production detour, full UInt64 GID, size replacement, unselected depot and beta passthrough, disabled-app reload, duplicate config, corrupt/missing/repaired cache, and detour removal. A separately copied and re-signed dylib with a changed UUID must be rejected. Only temporary test files are modified.

Full Steam download/update selection, coexistence under live client load, and future client builds still require actual-client regression. In-process installation/removal test APIs are for isolated probes; application deployment and removal require Steam to be closed.
