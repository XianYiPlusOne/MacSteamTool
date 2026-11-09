# NotProton WebUI repair

Independent Fluent Steam Mac modification of NotProton commit
`692b470e73d0d497ee9e474038efda819a037772` (1.2.3), GPL-3.0.
Original project: https://github.com/NotProtonNot/NotProton
License: ../../Licenses/NotProton.txt

`webui-capacity.patch` expands the eight-slot WebUI table and eight route-specific
factory functions to sixteen, with a compile-time capacity/factory count check.
The ninth existing service, OpenPrefixLog, otherwise cannot register. The patched
kernel identifies itself as `1.2.3-fluent.1`. No game, Wine, Steam bridge, or runner
payload is modified by this patch.

`script/build_notproton_kernel.py` extracts the fixed original commit into an
isolated source directory, applies this patch, and builds its dylib target with
the existing pinned Dobby static library and Fluent's documented Darwin code-page
writer. It does not modify the reference checkout or install anything. Rebuild
using `script/build_and_run.sh --build`. The resulting source checkout is
`work/notproton-kernel-source`; corresponding original source, patch, build script,
and licenses remain available. This is not an official NotProton binary.

`script/test_notproton_routes.py` runs actual registration and factory code with
AddressSanitizer/UndefinedBehaviorSanitizer. Original code must reject route 9;
patched code must accept all required routes, retain the right job identity for
every slot, reuse rejected registration slots, and reject capacity overflow.

The installer only repairs an already installed 1.2.3 kernel, validates the repair
receipt/digest/signature, backs up Steam, preserves other inserts and environment,
and supports rollback. It does not replace runner data, prefixes, or profiles.
