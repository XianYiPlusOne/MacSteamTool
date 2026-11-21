# Reviewed native Steam profiles

Supported ARM64 clients: 1792618285 (UUID 1D282616-B67E-30A6-B0AF-E4D5880610E7), 1794424036 (UUID 633E6624-A521-3F89-AD7D-B3320C4EE73B), and 1794536281 (UUID 221FAA3A-6A2C-36C9-9130-B0A45028AF1B).

`profiles.json` records binary SHA-256, UUID, exact instruction bytes and layout values. Regenerate the C++ adapter header with `python3 script/generate_steam_profile_header.py`. These values come from local old/new Steam clients; no manager app supplies executable components.

The maintained macSteam resolver selects a matching UUID, checks every exact entry, and refuses partial resolution. Old wildcard/string anchors are retained as analysis evidence only; they cannot activate hooks. NotProton build 1794424036 has 25 independently resolved anchors, recorded sites and unique exact fallback patterns across steamclient, steamui and steamservice.

Verified changes in 1794424036:

- Engine global 0x1876438 → 0x18b3ca8; app-info cache 0x1518 → 0x15c8. Native getAppInfo accesses tree root +0x28 / nodes +0x40 (previous +0x68 / +0x80). Production uses the native accessor; fixture layouts now follow the selected profile.
- Package cache 0x1610 → 0x1680, established by constructor call sites 0xa154bc / 0xa47ca0. Clear the map at cache +8 through 0x5a35e8 / 0x5bb2dc. The prior recorded 0x5a35d4 was a deleting destructor and must not be used for map clearing.
- The engine-reference anchor's ADRP is +0x48, not the inherited +0x40. The maintained implementation uses the UUID-scoped global directly. The IPC GetSubscribedApps proxy is not passed to native CUser refresh functions.
- Player.GetUserStats#1 worker is 0xb15bd4 → 0xb49438. The old wildcard pattern incorrectly selected 0x78b5fc. Worker owner/game fields are +0x180/+0x188 → +0x190/+0x198; transport return is 0xb15d70 → 0xb495d4, with response count at SP+0x80.
- Encrypted-ticket job app/user fields +0x16c/+0x180 → +0x17c/+0x190; CUser ticket tree root +0x6388 → +0x6488; engine current-app root/nodes +0x13e0/+0x13f8 → +0x1450/+0x1468.
- Cloud-enabled vtable slot remains 24, now additionally checked against the selected exact function. Native protobuf, KV, manifest, ticket and playtime adapter sites all use the same profile table.
- Owned macSteam exports `fluent_macsteam_ownership_abi=1`; the cloud adapter accepts this explicit source ABI instead of requiring the UUID of an upstream app's compiled dylib. Official legacy 0.8.2 remains separately guarded. Native owner IDs are no longer read from the obsolete CUser +0x27a layout.

The buffer cleanup helper at 0xfa6b0 is instruction-equivalent to the old 0xa0f0c helper, including allocation flags and the same allocator service; actual Steam buffer allocation/write/destruction is exercised by the runtime probe. Similarity scores were used to propose matches, never as runtime acceptance criteria.

## 1794536281 (2026-11-14)

The client updated from 1794424036; its new UUID correctly caused the previous exact profiles to refuse activation. Added a separate macSteam profile and adapter profile after comparing the complete normalized functions in local old/new ARM64 images, checking instruction differences and unchanged object layouts. Duplicate ClearMap code was disambiguated through its following function. Engine global remains 0x18b3ca8, package cache +0x1680, app-info cache +0x15c8, and stats worker fields +0x190/+0x198. Existing UUID and exact-entry validation remains enabled.

Read-only real-client probe resolved all 32 required sites and rejected altered UUID/entry guards. Native runtime, ownership, and live startup validation passed. Live Steam loaded the two configured Flotsam entries and installed 18/18 hooks. This update covers macSteam and the cloud/manifest adapters; it does not claim new NotProton runner compatibility or successful game launch.
