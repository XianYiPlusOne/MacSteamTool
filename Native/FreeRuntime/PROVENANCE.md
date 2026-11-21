# Fluent free runtime (experimental)

The app registers `fluent-proton-free` with native Mac Steam. The existing NotProton kernel enables compatibility tool discovery; this integration does not replace it or change the commercial CrossOver backend's license checks.

`Resources/FreeRuntime/run` is derived from Drustburn/NotProton `dylib/feats/compat_run.sh`, commit `df2f23a71bd42151e9aec923b1a01e50efcb8505`, GPL-3.0 (see `Licenses/NotProton.txt`). Changes: app-managed runtime path, independent `compatdata/<appid>/fluent-free/pfx`, distinct launcher bundle identifiers, no native Steam file writes during launch, shell variable name validation, no ambient Steam environment dump, safely quoted generated launcher, and clear failure when an unavailable D3DMetal backend is requested. The upstream source remains at <https://github.com/Drustburn/NotProton/tree/df2f23a71bd42151e9aec923b1a01e50efcb8505>.

Wine + DXMT comes from steamplay-mac `v2026.10.13`, commit `e350a87013fcbd4c81c33b59e8081f943b271955`. The release DMG SHA-256 is `4d2446faa89f8c72838ca419df5b76d76a8d9ac52bea11cb47dd731ea83f85a8`. It is downloaded on demand, not embedded in our app. Public-source build scripts and runner provenance: <https://github.com/Drustburn/steamplay-mac/tree/e350a87013fcbd4c81c33b59e8081f943b271955>.

`valve-packages.manifest` comes from the same NotProton commit. Valve packages and extracted files are checked against its hashes and fetched from Valve CDN. Valve binaries are not committed or included in our app bundle. Apple D3DMetal is not installed by this product integration; it was tested separately in `Native/SteamPlayValidation`.

The manifest also pins `bins_win32.zip.23e34a6d4b10596a44561a5100dac5585d2517da` from Valve's `steam_client_win32` package manifest retrieved on 2026-11-18. Its SHA-256 and the extracted `tier0_s.dll` / `vstdlib_s.dll` hashes are recorded alongside the existing packages. These dependencies are staged for 32-bit launchers using `steamclient.dll`; the original integration staged only their 64-bit counterparts.

The installer prepares a version directory, verifies the pinned artifacts, and only then registers the tool with Steam stopped. Previous tool registration and runner versions remain available in `FreeRuntime/backups` and `FreeRuntime/versions`. Game selection uses the existing backed-up compatibility transaction. First launch creates a separate prefix; no save migration occurs. Native Steam remains the account, game library and launch client.

If CloudRedirect is installed, setup first updates it through the existing backed-up kernel deployment transaction so Windows save discovery follows the selected free prefix. A readiness marker is committed only afterwards. Early prototypes without that marker refuse game launch until repaired, preventing use with the older save-path resolver. The native resolver and Swift library/tool/save discovery all follow the same per-game mapping and global fallback. This is not an end-to-end cloud sync certification.

Current limits: Apple Silicon + Rosetta; DX11/DXMT first; existing NotProton kernel required. A fresh-machine installer for macSteam/NotProton kernels, complete runtime rebuild, formal signing/notarization and distribution review remain separate work. Automatic installscript processing for games needing absent native-client `legacycompat` components is not claimed by this MVP.
