# Fluent's native Steam library integration

Maintained source port of macSteam revision
`f6d5525905ed5943ae61734783a591d98133afe4` (0.8.2):
https://github.com/crghofficial/macsteam

License: AGPL-3.0, retained in `LICENSE` and `../../Licenses/macSteam.txt`.
`upstream.json` records each original imported source/profile digest. Our changes
are ordinary repository changes against that baseline, not a clean-room rewrite.

The runtime implementation now lives in `src/`: configuration parsing, native
Steam feature hooks, signature resolution and session reconciliation. Fluent's
existing Swift services own import/edit/backup and automatic initialization.
`../SteamIntegration/CMakeLists.txt` compiles this implementation with pinned
Dobby. `script/build_native_integration.py` adds the Intel bootstrap stub.

Fluent removes the upstream relaunch rewrite to `/Applications/macSteam.app`.
The native Steam bundle contains the deployed library and launch environment,
so native Steam keeps its own restart command. Launch argv are not logged.
There is no manager UI/executable in this subtree, nor an app archive in the
build/runtime input chain. Signature profiles remain compatibility data.
