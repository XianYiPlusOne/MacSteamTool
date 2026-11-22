# NotProton WebUI repair

Independent MacSteamTool modification of NotProton commit
`692b470e73d0d497ee9e474038efda819a037772` (1.2.3), GPL-3.0.
Original project: https://github.com/NotProtonNot/NotProton
License: ../../Licenses/NotProton.txt

`webui-capacity.patch` expands the eight-slot WebUI table and eight route-specific
factory functions to sixteen, with a compile-time capacity/factory count check.
The ninth existing service, OpenPrefixLog, otherwise cannot register. The patched
kernel identifies itself as `1.2.3-fluent.1`. No game, Wine, Steam bridge, or runner
payload is modified by this patch.

The repair is now applied directly to maintained source in
`Native/NotProtonCore`. `script/build_native_integration.py` compiles it alongside
the native library integration. `script/build_notproton_kernel.py` is only a
compatibility entrypoint. Neither build nor tests require an upstream checkout
or original app. Source, licenses and modifications are shipped with this project.

`script/test_notproton_routes.py` runs actual registration and factory code with
AddressSanitizer/UndefinedBehaviorSanitizer. Original code must reject route 9;
patched code must accept all required routes, retain the right job identity for
every slot, reuse rejected registration slots, and reject capacity overflow.

The installer only repairs an already installed 1.2.3 kernel, validates the repair
receipt/digest/signature, backs up Steam, preserves other inserts and environment,
and supports rollback. It does not replace runner data, prefixes, or profiles.
