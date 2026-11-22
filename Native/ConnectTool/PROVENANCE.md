# Embedded ConnectTool service

Based on [moeleak/connecttool-qt 1.6.0](https://github.com/moeleak/connecttool-qt/tree/7a2d7aae95010a38badb6f6cc501a685601d9cfa), commit `7a2d7aae95010a38badb6f6cc501a685601d9cfa`, MIT, copyright 2025 Ji Fuyao. The included `upstream/` source retains its network, Steam lobby/chat, TCP forwarding, virtual network, TUN helper and update implementations. Full original license: `upstream/LICENSE`.

MacSteamTool changes:

- `Bridge.cpp` runs `ApplicationRuntime` with **QCoreApplication**, no window, QML engine, tray or standalone application. Bounded newline-delimited JSON over inherited pipes exposes state and commands to the SwiftUI multiplayer page. Steam diagnostics go to stderr. EOF or parent death leaves the lobby and stops the service.
- Model headers omit QML registration macros. Runtime omits the unused QQmlEngine include. The host implements clipboard, reminders, friend-profile links, navigation and all visible controls. No Steam network payload, room metadata or protocol format is changed.
- TUN setup is managed by the native `TunHelperController` and `TunHelperSetup` transaction. Explicit system authorization installs signature/hash-verified, root-owned assets; launchd failures are propagated and old assets restored on failure. Both root and the signed-in user must pass a real, transient utun creation test before success is reported. The old error-swallowing installer is removed. The helper is universal arm64/x86_64, has a `--probe` client mode, bounded socket I/O and complete stream/descriptor framing. No third-party driver is installed; macOS provides utun (https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_utun.c).
- `sendChatMessage` returns the actual send result so the host only clears a successfully submitted message.
- CMake builds the service, TUN daemon and upstream protocol tests without Qt Quick. Swift IPC and controller are in `Sources/MacSteamToolCore/ConnectTool.swift` and `Sources/MacSteamTool/MultiplayerController.swift`.

## Dependencies and rebuilding

Run `python3 script/bundle_connecttool.py <destination>` or `script/build_and_run.sh --build` from the repository. Requires macOS 14+, Xcode command line tools, CMake >=3.28, Python >=3.11, and network access for a first build. Cached downloads are SHA-256 checked and reused. Intel Steamworks libraries require Rosetta 2 on Apple Silicon.

- Unmodified Qt **6.11.1** Core/Gui/Network/DBus frameworks and native TLS plugin, plus Valve Steamworks `libsteam_api.dylib`/`libsteamwebrtc.dylib`, are extracted from the official, hash-pinned DMG in `Resources/ConnectTool/release.json`. The original GUI executable, QML, fonts and .app are **not** shipped. Steam AppID is 480 as in upstream; users sign in with their own Steam client.
- Build-time Qt Base SDK **6.11.1**, installed with aqtinstall **3.3.0** using Qt's archive checksums. Qt is dynamically linked under LGPL-3.0; LGPL/GPL license texts are bundled. Matching sources: https://download.qt.io/archive/qt/6.11/6.11.1/submodules/ . The libraries can be replaced and the local application ad-hoc signed using `codesign --force --deep --sign -`.
- Boost **1.88.0** headers (Boost Software License 1.0), official archive SHA-256 `3621533e820dcab1e8012afd583c0c73cf0f77694952b81352bf38c1488f9cb4`.
- Steamworks SDK 1.65 headers from ValveSoftware/Proton commit `164e0ccd2ea2b1ec2e5d08dc97f65b184c2539ca`, archive SHA-256 `136aa6600501e279dba0b1efaee9f81e837d043a296f4286e1d3f966ca1e007a`. Build preparation restores C++ inline sections disabled by Proton and anonymous unions in SteamNetworkingIPAddr/SteamNetworkingIdentity; binary layouts are unchanged. Headers remain in the build cache. Valve redistributable binaries are retained unmodified except local signing.
- cute_sound 2.08 and its hashtable retain the zlib/MIT notices in `Licenses/CuteSound-NOTICE.txt`; audio reminders are provided by the native host.

`ctest --test-dir work/connecttool-native-build --output-on-failure` exercises upstream protocol/codec tests (the Steam dylib must be on DYLD_LIBRARY_PATH for build-tree tests). `script/verify_connecttool_bundle.sh <destination>` checks signatures, dependency closure, absence of external build paths, and absence of the independent GUI.

This integration is maintained independently and is not endorsed by ConnectTool or Valve. Source changes and corresponding object rebuilds are available in this repository.
