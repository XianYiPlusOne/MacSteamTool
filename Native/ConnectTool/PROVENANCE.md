# Swift multiplayer and ConnectTool 1.6.0

The Mac application owns the lobby, chat, TCP streams, virtual IP negotiation and packet routing. Swift calls Valve's Steamworks SDK through the in-process C ABI in `SteamBindings.cpp`. Steam matchmaking uses AppID 480, TCP uses SteamNetworkingSockets virtual port 0, and virtual LAN uses SteamNetworkingMessages channel 0. The signed launchd helper owns privileged utun setup. Swift holds the resulting descriptor and closes it when leaving the session.

## Build

Run `python3 script/bundle_connecttool.py <destination>` on macOS with Python 3.11+ and the Xcode command line tools. The script extracts the universal Valve library from the SHA-256-pinned release DMG and builds the ABI adapter and privileged helper for arm64 and x86_64. It obtains the SDK 1.65 headers from ValveSoftware/Proton revision `164e0ccd2ea2b1ec2e5d08dc97f65b184c2539ca`. Release verification checks the architecture, dependency closure and signature of each of the three binaries.

## Protocol reference

The reference implementation and utun helper come from [connecttool-qt 1.6.0](https://github.com/moeleak/connecttool-qt/tree/7a2d7aae95010a38badb6f6cc501a685601d9cfa). See `upstream/LICENSE` for the MIT license. The networking implementation is maintained independently of Valve and ConnectTool.

| Feature | Contract |
| --- | --- |
| Lobby | Public Steam lobby, 250 slots. Listed rooms advertise `ct_tag=1`. Both modes publish `ct_mode` (`tcp` or `tun`), `ct_name`, `ct_host_name`, `ct_host_id`, and `ct_ping_loc` when available. |
| Chat | UTF-8 lobby chat with no terminator. Host ping reports begin with `PING\|`. Pinned messages use `ct_pin` and the string fields `steamId`, `displayName`, `message` and `timestamp`. |
| TCP | Six ASCII alphanumeric bytes, one zero, then a little-endian 32-bit type. Data is type 0. Disconnect is type 1 with an empty body. Each Steam connection has its own stream IDs. The sender splits game data into chunks of up to 1100 bytes. |
| Virtual LAN | One byte of type and a big-endian 16-bit payload length. IPv4 fields are network order. Route Steam IDs and control timestamps are little endian. Node IDs use SHA-256 over the little-endian Steam ID and the 1.6.0 salt. IP packets travel unreliably and negotiation/control packets reliably. |

Run `script/test.sh --filter Multiplayer` to exercise the Swift session and the C++ reference. The frame tests compile the original codecs from source, decode their output in Swift and send Swift frames back through the original decoder. The checked-in `Tests/ConnectToolReference/win64.frames` contains the same 12 samples emitted by the MinGW-w64 build of the C++ oracle, run under Wine. Set `MP_TEST_WIN64_ORACLE` to an executable wrapper for that oracle to also decode the live Swift output in the Windows binary. The session test uses real loopback TCP sockets, a socket pair representing utun, and a local Steamworks fixture running the upstream C++ codecs and IP negotiator. A physical Mac/Windows game session and real Steam direct/relay routing require two signed-in accounts.
