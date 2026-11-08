CloudRedirect macOS ARM64 port

Upstream: https://github.com/huanyuejue/CloudRedirect
Revision: f5d122ddf18fbf5d0bacb8e914c665e965b15940
License: MIT (included). Common/provider sources copied unchanged initially. macos/ is adapted from upstream Linux sources for Mach-O, 64-bit ABI, macOS storage and peer authentication. This is an independent altered version.


Native runtime additions (2026-11-05)
- ARM64 Steam build 1792618285, Mach-O UUID 1D282616-B67E-30A6-B0AF-E4D5880610E7. Each detour requires exact entry bytes and the UUID.
- CCMInterface send 0x693cf8; CProtoBufMsg EMsg +40, header +48, body +56. Typed MessageLite factories and serializers remain Steam's own.
- CUser playtime writer 0xa7d1b0; repeated protobuf games count +24, rep +32, element array rep+8. Calls only from the Steam callback/send thread; shutdown drops pending UI work.
- CUser encrypted ticket getter 0xa762c4; job run 0xa84d20; original job completion 0x603068. Does not fabricate API call IDs or change ticket contents.
- macSteam 0.8.2's exported sx_ticket_serve_extended is wrapped, leaving its existing IPC detour intact. The interface's GetSteamID slot 10 is used for ownership-ticket account checks. Internal CUser identity +0x242 is checked for encrypted tickets/jobs. Imported tickets for other accounts pass through.
- The maintained Dobby source is pinned at 5dfc8546954ce3b3198132ab13fddb89ee92cdd7 (Apache-2.0); its public symbols are hidden from this dylib to avoid competing with macSteam's copy.
- Packet field references: https://github.com/OpenSteam001/OpenSteamTool/tree/main/src/proto and https://github.com/SteamRE/SteamKit/blob/master/SteamKit2/SteamKit2/Base/Generated/SteamLanguage.cs . Newly written ARM64 adapters are independent code; no Windows hook code is copied.

Verification: script/test_runtime_native.py uses installed native Steam/macSteam libraries in a separate process, a disconnected synthetic CM, copied Spacewar statistics, and an isolated folder provider. The optional --tickets path reads a locally extracted Spacewar ticket response without printing it. Ticket buffers are compared byte-for-byte. The real playtime writer is exercised with collectors at CUser service boundaries. This is an ABI/logic integration test, not a claim that a live Steam process or friend's client has been verified.

Live verification on the same build: the extension was deployed with complete Steam.app backups, then loaded together with macSteam 0.8.2 and NotProton 1.2.3. Native Steam and an actual Windows x64 process under runner 26.3.0.39832 consumed byte-identical cached AppID 480 ownership/encrypted tickets and callback 154. A 65-second Windows session added one Windows minute (zero Mac minutes) through the folder provider. Windows StoreStats unlock/relock returned successful Steam callbacks; a separate native process reread all five original locked states. Save redirection remained disabled. No friend-side client, Denuvo game, online cloud provider or second-device validation is claimed.

Reset handling: explicit StoreUserStats masks carry a persistent reset revision, merge independently of playtime, and reject older native/client-cloud unlock snapshots. Process IDs in GamesPlayed identify the Wine runner for Windows time; a native helper's earlier registration does not restart the timer. Protocol field definitions also checked against https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_clientserver.proto and steammessages_clientserver_userstats.proto.

Compatibility presence (0.2.6): independently implements shortcut-first / Spacewar fallback and most-recent-game selection after reviewing huanyuejue/OpenSteamTool revision de8189572db4495ec9d0d4d14ece1d2fc4703445, Hooks_NetPacket.cpp1095–1117. The bounded binary-KV reader and ARM64 typed-message adapter are newly written. No Windows hook implementation, blanket family owner mask or manufactured self-PersonaState packet is included. Current-account registered shortcuts only; local language requirement retained. Native isolated tests cover both branches without network sends; live friend visibility is recorded separately.
