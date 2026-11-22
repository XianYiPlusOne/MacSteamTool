NotProton installation adapter

Adapted from https://github.com/NotProtonNot/NotProton (local source revision recorded below), GPL-3.0; license in ../../Licenses/NotProton.txt.

Changes: command-line entry, resource bundle selected from the installed official companion, structured progress, refusal to stop running Steam, preserving macSteam / CloudRedirect / other DYLD inserts, and backup/rollback wrapper. No CrossOver or Wine binary is included here. Native core resources are packaged separately; see ../../Native/OneClickSetup/PROVENANCE.md.

0.2.13 adds guarded replacement of the installed 1.2.3 kernel with MacSteamTool's
WebUI route-capacity repair, including receipt validation and isolated
install/rollback tests. The separately bundled kernel source patch and build are
documented in ../../Native/NotProton/PROVENANCE.md. Other versions are refused;
this repair does not install or replace runners, profiles or game prefixes.
692b470e73d0d497ee9e474038efda819a037772

One-click setup integration (2026-11-11):
- Accept a MacSteamTool-owned component directory with a complete SHA-256 inventory,
  or retain the existing official companion path for manual management.
- Scope installation locks and Steam modification records to the configured
  Application Support directory.
- Adapt `PrefixTools.swift`, `PrefixRebuild.swift` and the
  `RebuildPrefixCommand` portion of upstream `Support/Launch.swift` from the
  same revision above. The bundled CLI handles `--rebuild-prefix`, so managed
  installs record MacSteamToolNotProton rather than an external manager executable.
- Add a generated-directory integration test; only that internal test path
  injects no-op Steam-idle and LaunchServices callbacks. Production installs
  still refuse running Steam and retain their backup/rollback checks.

Native core separation (2026-11-12):
- KernelSession deploys bundled NotProton core resources without BridgePayload,
  ValveFetcher, fonts, runner cloning, or prefix changes. Controller environment,
  versions, signatures and the bundled rebuild-helper record share one snapshot.
- The full installer remains the optional CrossOver backend adapter and legacy
  import route. Kernel recovery allowlists the new native resource destinations.
- `--test-core APP_BUNDLE` exercises real bundled libraries in a generated Steam
  fixture, verifies no backend installation, preserves existing choices/saves,
  injects a post-resource failure, and restores both kernel backups.

Source internalization (2026-11-12, supersedes release-resource packaging above):
- Native features, helpers, launch scripts and bridge build sources now live in
  `Native/NotProtonCore`; macSteam native code lives in `Native/MacSteam`.
- Managed CrossOver installs read MacSteamTool-built resources from our own app, never
  a downloaded NotProton app archive. Missing internal resources fail locally.
- No implicit `/Applications/NotProton.app` fallback is sent by the runtime API.
  Explicit legacy companion validation remains for compatibility tools only.
- Keep existing user font assets during managed imports. Included font families
  and bridge licenses are documented in `Native/NotProtonCore/PROVENANCE.md`.
- `--test-owned-backend APP CROSSOVER` tests the actual licensed local CrossOver
  clone, bridge patching and registration in disposable, empty directories.
