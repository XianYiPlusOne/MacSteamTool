# Internal native cores and optional translation backends

MacSteamTool owns the macSteam / NotProton installation, configuration and recovery
workflow. The native cores are bundled; external manager applications are not
required. The original native Mac Steam client is retained. Wine and licensed
CrossOver are optional, separately installed translation backends.

## Internal source implementations

The earlier release-package extraction approach has been replaced. Native
implementation sources are maintained in `Native/MacSteam` and
`Native/NotProtonCore`; installation and prefix/runner management are maintained
in `Engine/NotProtonInstaller`. Their PROVENANCE files record upstream revisions,
licenses and MacSteamTool changes. This is a source port, not a clean-room rewrite.

`script/build_native_integration.py` compiles native implementations and helpers.
`script/build_crossover_bridge.py` builds the backend bridge from our source and
pinned Wine/Valve source dependencies. `script/bundle_native_integration.py`
packages those artifacts and creates complete SHA-256 component inventories.
No macSteam or NotProton app/archive is part of the default build or runtime.

Core preparation reads only MacSteamTool's packaged components. CrossOver preparation
uses `RuntimeBackends/crossover`, including our built bridges and maintained
launcher, rather than downloading NotProton resources. Core and backend caches
are separate. Explicit legacy imports remain available to developer maintenance
code; they are never automatic fallbacks. Missing internal components fail
locally and request a complete MacSteamTool installation.

The user chooses Wine or their purchased, activated CrossOver. The original
native Mac Steam client is retained. Core initialization and repair are automatic;
Steam exit and Rosetta authorization are requested only when needed. Prefix
rebuilds record our own helper. Existing games, per-game choices and data layout
are retained. Native deployment does not install a backend automatically.

## Steam bootstrap architectures

Valve's initial Steam bootstrap is x86_64. CloudRedirect and MacSteamTool Manifest now
include `../BootstrapSupport/noop.c` as a no-hook Intel slice, alongside their
unchanged ARM64 implementation. `script/add_bootstrap_slice.sh` creates and signs
the universal libraries; `script/test_bootstrap_extensions.py` tests actual DYLD
startup loading and exported symbols for both architectures without launching
Steam. This corrects the first-launch architecture failure found during the
aborted fresh-machine trial; it is not a complete first-login acceptance test.
