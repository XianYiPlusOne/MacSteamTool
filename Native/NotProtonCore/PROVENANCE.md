# MacSteamTool's native Windows-game integration

Maintained source port of NotProton revision
`692b470e73d0d497ee9e474038efda819a037772` (1.2.3):
https://github.com/NotProtonNot/NotProton

Most source is GPL-3.0; preserve `LICENSE`, `NOTICE`, `LICENSE.lsteamclient`,
`LICENSE.steam-shim`, `LICENSE.fonts`, source notices and each font family license.
`upstream.json` records the initial imported source/asset digests. This is source
reuse with MacSteamTool modifications, not an independently authored clean-room clone.

The maintained implementation includes native compatibility registration,
Windows-platform launch hooks, compatibility settings routes, prefix state,
launch/environment handling, controller/overlay support and native helpers.
MacSteamTool's installer, runner cloning, licensed CrossOver checks, patching and prefix
rebuild logic are in `Engine/NotProtonInstaller`. Original manager UI and Sparkle
are not built. Existing on-disk names and tool IDs stay compatible with user data.

MacSteamTool changes: WebUI route capacity repair applied in source; repair messages
point to MacSteamTool; source-built helpers and launcher own prefix rebuilds. Core and
backend resources are separated. Existing fonts are preserved on managed imports.
Included fonts are unrenamed Noto and Ume assets from this revision, with their
licenses. The original manager's generated MS-named replacement font set is not
included; purchased CrossOver also supplies Wine fonts.

Build: `script/build_native_integration.py` compiles native code from this tree.
`script/build_crossover_bridge.py` compiles the bridge from these sources plus
Wine `2df1ee28039cf84776eb1421ed90bd154cebb65f`, Proton
`164e0ccd2ea2b1ec2e5d08dc97f65b184c2539ca`, and the digest-pinned headers in
`steam-shim/fetch-headers.sh`. Build caches live in `work/`, source lives here.
The scripts validate source revisions/digests. Neither NotProton.app nor
CrossOver.app is a build input. The small `Resources/detour*.bin` patch assets
are retained from the pinned source revision (not an app package); matching
assembly/C/linker and resolver sources are in `ntdll-patch/`, and the Swift
adapter validates each asset and target binary by SHA-256 before applying it.

At runtime, CrossOver is user-supplied and license-checked. Valve runtime DLLs
are fetched by the owned installer directly from pinned Valve packages. Wine
remains the independent optional backend documented in `../FreeRuntime`.
No original manager release package is downloaded or extracted.
