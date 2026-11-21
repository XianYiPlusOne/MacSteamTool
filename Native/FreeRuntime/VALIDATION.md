# App integration validation — 2026-11-11

Scope: optional application-managed Wine/DXMT runtime with native Mac Steam. Earlier isolated graphics and game results remain in `Native/SteamPlayValidation/VALIDATION.md`.

## Passed

- Pinned release preparation, hash-checked Valve bridge extraction and tool registration on this Mac, without reading a paid CrossOver runner.
- Steam build 1792618285 discovered `fluent-proton-free`, registered it as AppID 0 and mapped ForgeTax 5245810 to it. `compat_log.txt` contains the registration and mapping at 23:00:01.
- Steam's own launch pipeline invoked the registered `run waitforexitandrun .../ForgeTax.exe` at 23:01:11. This first integration attempt stopped before launching the game because upstream auto detection preferred D3D12 merely due to bundled Agility files. The November 11 build used DXMT for the subsequent ForgeTax test.
- Final native-Steam launch passed after the fix and completed installation. The user confirmed a normal game image. PID 88843 loaded Wine from the app-managed free version, DXMT and lsteamclient; no commercial CrossOver installation or paid NotProton runner path appeared in the loaded module evidence. Unity reported Direct3D 11.0 / feature level 11.1 on Apple M4 Pro, and the game reported Steam `Connected`.
- The installed launcher subsequently initialized a separate test prefix and passed the D3D11 GPU render/readback probe (`RGBA=255,0,0,255`), using the installed free runtime. That test process was cleaned up via its own wineserver/prefix.
- 27 targeted Swift tests: prefix selection/isolation, failed download preservation, unsafe shell variable names, readiness gate, compatibility mappings and automatic selection, save handling and startup diagnostics.
- Native CloudRedirect isolated tests: existing paid prefix mapping, selected free prefix in an external library, no fallback to paid saves before the free prefix exists, provider failure and a complete synthetic save upload/download roundtrip. No real saves or external cloud account were used.
- App packaging and launch through `script/build_and_run.sh --verify`.
- At the post-test checkpoint, existing paid `user.reg` and `system.reg`, deployed macSteam/NotProton/CloudRedirect/Manifest dylibs and Steam Info.plist remained unchanged. `config.vdf` changed as expected for the backed-up per-game selection and normal Steam operation.

## Native launch outcome and remaining scope

Steam initially reported no connection and displayed a cloud-sync-failed confirmation. CUA could not attach because ScreenCaptureKit capture failed. An overlapping request to exit Steam caused the first post-fix game startup to lose its native Steam connection. The test was repeated with Steam left running; the user accepted the cloud prompt and explicitly confirmed a normal game image. This is a manual visual confirmation, supported by the process, module and Unity/Steam log evidence.

A later inspection found CloudRedirect's original resolver still selected the paid prefix. Source, tests and installer were updated: installing the free runtime updates an existing CloudRedirect through the normal Steam backup/deployment transaction before registering the tool as ready. After the separate ConnectTool session ended, Steam was gracefully closed and the packaged app's installer completed this repair. The tool is marked ready. The final successful test retained native Steam and the game running.

The completed repair changed `cloud_redirect.dylib` and Steam Info.plist (the backed-up injection configuration), in addition to the expected Steam config changes. Deployed macSteam, NotProton and Manifest libraries and the old paid prefix registries remained byte-identical. The new version is `FreeRuntime/versions/2026.10.13-e350a87-9A3C47C2-ECA2-427C-94B4-7710DAB2D7BE`; the prior version remains available.

Both the earlier isolated test and the final integrated native-Steam launch received separate user confirmations. The final game log reports achievements `Connected`, but `readable=0/19`; this is not a successful achievement-sync acceptance. Long gameplay, DX12 and production cloud synchronization remain unaccepted. macSteam/NotProton kernels are still the existing deployed components; fresh-machine single-app bootstrap is not implemented by this patch. All 23 checked old-prefix LocalLow files remained unchanged after the final launch.

## Evidence

Ignored local artifacts under `work/free-runtime-native-test/`: `before.json`, `after.json`, `config.vdf.before`, `select.log`, `installed-launcher-dx11.result.txt`, `probe-compatdata/fluent-free/notproton-run.log`. Standard logs: `work/free-runtime-tests.log`, `work/free-runtime-cloud-tests.log`, `work/free-runtime-build.log`.

Final evidence: `acceptance.json`, `native-success-Player.log`, `native-success-run.log`, `after-repair.json` and `paid-saves-before.json`. The unsuccessful first post-fix launch is preserved separately in `native-first-Player.log`.

Per-game selection backup: `~/Library/Application Support/FluentSteamMac/CompatibilityBackups/2026-11-11T14-59-58Z-5D697FF1`. Use app compatibility selection while Steam is closed to return ForgeTax to its existing CrossOver option; both prefixes are retained.

## Renderer selection and Retina, 2026-11-21

Ran the product Wine preparation script with verified local copies of the pinned DMG, Valve packages, DXVK and GPTK. Invoked its Steam tool entry point with `waitforexitandrun` in a temporary library on an Apple M4 Pro. The probe ran through the raw loader branch to exercise each renderer on the same prefix.

| Selection | Probe | GPU readback |
| --- | --- | --- |
| DXVK | D3D11 | RGBA 255, 0, 0, 255. The renderer log identified DXVK 1.10.3 for macOS. |
| WineD3D | D3D11 | RGBA 255, 0, 0, 255 |
| DXMT | D3D11 | RGBA 255, 0, 0, 255 |
| D3DMetal | D3D12 | RGBA 0, 255, 0, 255 |
| Automatic | D3D12 | Identified the probe's D3D12 import, selected D3DMetal and read back RGBA 0, 255, 0, 255 |

Toggled High Resolution on, off, on and off across these launches. Wine persisted 192 DPI with Retina enabled and 96 DPI after disabling it. This run covered the launcher and graphics probes. The earlier ForgeTax entry above records the separate Steam game test.

With DXMT selected globally, a per-game DXVK override reached both the game process and a subsequent `run cmd /c set` helper in the same prefix. The helper also retained the game's MSync, Retina, Metal HUD and AVX settings along with the inherited DXMT configuration.
