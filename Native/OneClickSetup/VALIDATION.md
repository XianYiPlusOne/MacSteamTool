> 2026-11-12 更新：下面的旧安装包提取记录是历史验证。
> 当前实现已改为 `Native/MacSteam`、`Native/NotProtonCore` 源码构建；
> `validate-setup` 的 `-` 参数读取 Fluent 内置实现，不再下载上游管理器。
> 当前验证见 `outputs/2026-11-12-源码内部化与外置依赖移除.md`。

# Managed one-click setup

Implemented and tested on Apple Silicon, 2026-11-11–12.

## Product flow

Opening Fluent now starts automatic inspection and initialization. There is no
manual core setup, install or update action in the normal UI. The health check
compares native library inserts, deployed bytes, support resources and the owned
prefix-rebuild helper path against the packaged track. Healthy installations are
left alone; Steam updates or missing/corrupt managed files trigger preparation.
Newer installed native cores are preserved.

Users choose Wine or a purchased, activated CrossOver installation. Their choice
queues behind initialization and resumes automatically when Steam closes. Rosetta
is requested only when needed, with explicit license consent and macOS system
authorization. Cancellation retains the pending choice. An explicit backend choice
sets the global default through a backed-up transaction; per-game choices remain.
The native-core step alone never chooses or downloads a translation backend.

Preparation never stops Steam automatically. The displayed exit control requests
a graceful quit; games/Steam may delay it. Errors are latched instead of generating
repeated installs/prompts. Diagnostics and backup recovery are under an advanced
disclosure. Source and binary provenance remain in `PROVENANCE.md`.

Requires Apple Silicon and macOS 15+. Rosetta installation requires an explicit
license checkbox and, when requested by macOS, administrator authentication.
Steam must be closed during deployment. On first launch Steam updates itself
and the user signs in. An unknown/uninitialized Steam build is recorded as
awaiting first launch; completion of file installation is not a claim that
hooks or a game have loaded successfully on that machine.

## Preservation and recovery

- Existing Steam applications are retained; a fresh Valve download is checked
  for the official bundle ID, full code signature and Valve team ID.
- Existing global choices, including explicit automatic/empty mappings, and
  every per-game compatibility choice remain untouched by core configuration.
- Existing macSteam configuration bytes are kept unchanged. Game directories
  and save prefixes are outside setup's mutation roots.
- Each kernel deployment retains its existing snapshot/rollback transaction.
  `FluentSteamMac/Setup/latest.json` records completed steps, errors and backups.
  A failed later step does not pretend the entire setup was rolled back.
- Retrying revalidates owned components. Interrupted deployment backups must
  be recovered using the existing recovery UI before another setup attempt.
- Component receipts cover every regular file, reject symlinks and unlisted
  files, and use relative names across staging moves and `/var` aliases.

## Automatic flow validation (2026-11-12)

- Controller tests: first-launch automatic initialization, healthy-running Steam
  without an exit request, queued Wine/CrossOver selection and automatic resumption,
  Steam restarting during preparation, Rosetta consent/cancel/retry, failure latch
  and retry, coalesced concurrent checks, and deferral while another operation runs.
- File-state tests: loss/corruption of managed resources, moved rebuild-helper path,
  newer-version preservation, game-config independence and default-only selection.
- Evidence: `work/automatic-initialization-tests.log`.

## Native core separation validation (2026-11-12)

Reproduction: `APP/Contents/Helpers/NotProton/MacSteamToolNotProton --test-core APP`.
The fixture is created under a fresh temporary root with the real bundled native
libraries. It does not launch Steam, access external managers, or deploy a backend.
It verifies both launch inserts and signatures, the bundled rebuild-helper record,
absence of bridge/font/runtime/download directories, retention of existing runner
files, game saves and manual choices, post-deployment failure rollback and recovery
of both native kernel backups. Evidence: `work/internal-core-integration.log`.

Swift tests also exercise bundled-resource preparation with a nonexistent download
engine, independent core/backend cache paths, corrupt-cache repair, rejection of a
corrupt embedded payload and absence of a default compatibility mapping.
Evidence: `work/internal-core-tests.log` (208 core tests + 26 app tests passed).
`script/verify_bundled_cores.py` checks the final signed package: macSteam has
5 native resource files and NotProton has 10, with complete matching inventories.
Both x86_64 bootstrap and ARM64 extension loading probes passed; see
`work/internal-bootstrap-extensions.log`.

The live fresh-machine trial was stopped when the user clarified the architecture.
It had downloaded native Steam and components but had not reached Steam login or
game startup. All original apps/support directories were restored, with all 37
configuration/save hashes matching. Trial journal: `work/fresh-machine-e2e/state.json`.
The trial exposed the Intel bootstrap extension issue; the separate architecture
probe is recorded in `work/fresh-machine-e2e/bootstrap-probe.log`.

## Earlier combined-flow validation (superseded product flow)

The CLI generated empty temporary directories, never set `HOME`, never
registered or launched their Steam fixtures, and left the actual Steam session
running. The integration exercise used real binaries, not substitute kernels.

1. Downloaded native Steam from Valve; verified its signature and installed it
   into an empty Applications directory.
2. Downloaded the pinned official macSteam and NotProton releases through the
   same metadata/download APIs used by setup, checked their hashes/signatures,
   then imported and verified the owned component inventories.
3. Installed both kernels into a copy of the pristine Steam bootstrap app with
   an intentionally nonexistent companion path. Checked both launch inserts,
   kernel versions, code signature and the bundled rebuild executable record.
4. Injected a failure after NotProton deployment and verified the Steam bundle
   and full NotProton support tree returned to their exact previous digests.
5. Applied the bundled NotProton repair and rejected an unlisted component file.
6. In the same generated installation, installed the pinned free runtime and
   seeded its default configuration. Verified both kernels, a complete runtime
   registration and the configured default tool together. The 325 MB runtime
   archive was supplied from the earlier verified download; Valve packages were
   reused from this fixture's just-completed NotProton installation and checked
   again. The runtime phase was resumed after eliminating duplicate downloads.

Evidence: `work/oneclick-validation/integration.log` and
`work/oneclick-validation/runtime-completion.log`.
Reproduction: `MacSteamToolRuntime validate-setup APP_BUNDLE - - STEAM_DMG FREE_DMG`.
The two `-` arguments now select Fluent-owned source-built components;
`STEAM_DMG` may also be `-` for a fresh Valve download.

Swift tests cover configuration preservation, missing installer journaling,
no downgrades, complete inventory checks, staging moves, verified package reuse,
async process exit and cancellation cleanup. The installation adapter's
`--self-test` also passed snapshot integrity, rollback and competing-lock checks.
The final app was packaged and launched using `script/build_and_run.sh --verify`.

## Remaining acceptance boundaries

- This is an empty-directory installation test on the current Mac, not an
  untouched physical Mac's first-login test. Rosetta was already installed;
  the system authorization/installation branch was not executed here.
- No new paid CrossOver activation or paid-runner cloning was performed during
  this test. That mode keeps the existing licensed-source installer path.
- Actual game validation remains the earlier native Steam → free Wine → ForgeTax
  test with user-confirmed normal rendering; see `../FreeRuntime/VALIDATION.md`.
  This does not establish DX12 support, all-game compatibility or full cloud
  synchronization on a fresh machine.

Official sources: [macSteam 0.8.2](https://github.com/crghofficial/macsteam/releases/tag/v0.8.2),
[NotProton 1.2.3](https://github.com/NotProtonNot/NotProton/releases/tag/v1.2.3),
[steamplay-mac](https://github.com/Drustburn/steamplay-mac/releases/tag/v2026.10.13),
[native Steam](https://store.steampowered.com/about/).
