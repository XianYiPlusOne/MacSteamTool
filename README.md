<p align="center">
  <img src="Resources/AppIcon.png" width="112" height="112" alt="MacSteamTool's indigo gamepad icon">
</p>

<h1 align="center">MacSteamTool</h1>

<p align="center"><strong>English</strong> · <a href="README.zh-CN.md" hreflang="zh-CN">简体中文</a></p>

<p align="center">
  Find games and add them to your Steam library on Mac, run compatible Windows games with Wine or CrossOver, and host multiplayer rooms for friends over Steam.<br>
  <sub>Universal arm64/x86_64 · SwiftUI · AGPL-3.0</sub>
</p>

> [!IMPORTANT]
> **MacSteamTool is a vibe coding project.** We develop it with AI assistance, and many features have yet to be tested in detail. Coverage is limited across games, Wine and CrossOver versions, and multiplayer sessions between two physical devices. Back up important saves before restoring files or resetting a game container.

## Discover games and manage manifests

- **Discover** lets you search by title or Steam AppID and browse the XiaoHeiHe popular games chart. Results show macOS and Windows availability. **Add to library** checks the base game, optional DLC, and their content depots, and lists anything still missing. Once the checks pass, the app adds the entry to your library. Steam handles licensing, installation, and downloads.
- **Library** shows installed Steam games alongside imported entries. Drag in Lua manifests or manifest archives, filter by name, AppID, or installation status, and enable or disable imported entries in bulk. Export the current list's manifests as a ZIP, or open a game's details to edit its Lua manifest and compare it with Steam's published DLC and depot data.
- **Manifests** groups cached manifest files by game. Fetch a missing file by DepotID and ManifestID, or monitor new manifest requests for enabled games. Downloads pass format and CRC checks before they enter the cache.

## Run Windows games on Mac

- **Runners and containers.** Choose MacSteamTool Wine or an activated copy of CrossOver as the default, then override it for individual games. To try different configurations, create separate containers for the same game. Run EXE or MSI files inside a container, inspect its logs, or back up and restore the whole environment.
- **Offline tools (experimental).** Generate an offline launch configuration for a selected Windows game. Preview which files will be added or replaced and back them up before deployment. Use the deployment record to check whether a patch loaded or to restore the files.

## Multiplayer, achievements, and saves

- **Multiplayer.** Host or join rooms over Steam, browse public lobbies, invite friends, and chat. TCP forwarding and TUN virtual LAN target compatibility with ConnectTool 1.6.0 on Windows. Players need compatible game versions and a game that supports LAN play or direct connections. Initial TUN setup requires administrator approval.
- **Achievements and playtime.** Read achievement progress by game, filter the list, and unlock or relock achievements. Games using compatibility achievements store edits in their compatibility records. Enable achievement and statistics sync or track playtime for selected AppIDs.
- **Local saves and backups.** Find save folders by game or add a custom folder. Backups are verified file by file. Restoring preserves a rollback copy of your current saves, and a reinstalled game can reuse an earlier backup. Steam handles the game's own Steam Cloud saves.
- **Accounts and friend activity.** Switch between accounts remembered by Steam and launch the client. Choose whether friends see activity for selected games.

In **Settings**, manage download sources and caches, check an HTTPS update feed, or import a signed local update. MacSteamTool verifies the update before installing it and keeps the previous app version.

## First launch

The **Getting started** guide checks whether Steam is installed. If needed, you can download Valve's official client from the guide. Once Steam is installed, the guide automatically shows the runtime choices.

- **Already have Wine or CrossOver?** The guide shows the installation path so you can select your existing copy. CrossOver requires your own activated copy.
- **Need Wine?** Select **Install Wine** to download the runtime and graphics components.
- **Want to explore first?** Select **Manage local games only** to skip runner setup. You can still open **Discover**, **Manifests**, or **Runtime** from the sidebar later.

On Apple silicon, MacSteamTool running as Intel or ARM can open an installed Intel, ARM, or universal Steam client. macOS selects the architecture using Steam’s own launch preferences. Runtime environment → Diagnostics and recovery shows the architectures in the Steam executable and the architecture of the running client.

The application, native libraries, and `MacSteamToolNotProton` installation/recovery helper are built as **universal arm64/x86_64** binaries. The helper supports installation, backup, and restoration on Intel; CrossOver registration excludes ARM FEX runners on Intel. Intel macSteam and NotProton profiles now cover Steam build `1794536281`, including compatibility tool registration, listing, and selection. Unknown builds do not reuse old addresses. Isolated x86_64 tests pass on Apple silicon; full game launch still requires validation on physical Intel hardware. NotProton Intel instruction hooks reject Rosetta-translated processes; use native ARM Steam on Apple silicon. Native integration has additional version and architecture requirements. For example, an Intel-only client requires a `macos.x86_64` profile for its Steam build. Automatic installation also checks for a profile for the architecture running MacSteamTool. The app runs on **macOS 14 or later**. Automatic setup requires **macOS 15 or later**. Some Steam integration features modify the local client and affect ownership checks for games and DLC.

## Open-source acknowledgments

We thank the authors and contributors whose work made these features possible.

| Project | Contribution to MacSteamTool |
| --- | --- |
| **[NotProton](https://github.com/NotProtonNot/NotProton)** | Provided the basis for the Windows game runner, CrossOver integration, and game container management. Thanks to [NotProtonNot](https://github.com/NotProtonNot/NotProton) and to [Drustburn](https://github.com/Drustburn/NotProton) for the Wine launcher fork. |
| **[macSteam Config (macSteam)](https://github.com/crghofficial/macsteam)** | Provided the local Steam configuration format and native components. Thanks to crghofficial and the macSteam contributors. [Upstream license](Licenses/macSteam.txt) |
| **[OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool)** | Served as a compatibility reference for Steam message formats and how friends' game activity is displayed. Thanks to OpenSteam001 and the project contributors. [Upstream license](https://github.com/OpenSteam001/OpenSteamTool/blob/main/LICENSE) |
| **[Fluent-Steam-Lua](https://github.com/huanyuejue/Fluent-Steam-Lua)** | Informed the Lua manifest format and the workflow for managing manifests. Thanks to huanyuejue and the project contributors. [Upstream license](Licenses/Fluent-Steam-Lua.txt) |
| **[ConnectTool (connecttool-qt)](https://github.com/moeleak/connecttool-qt)** | Provided the multiplayer room protocol and virtual LAN components. The Mac app implements session handling in Swift and targets compatibility with ConnectTool 1.6.0. Thanks to Ji Fuyao and the [ConnectTool contributors](https://github.com/moeleak/connecttool-qt). |

MacSteamTool uses the [GNU AGPL-3.0 license](LICENSE). For third-party authors, sources, modifications, and license terms, see the [third-party notices](THIRD-PARTY-NOTICES.md) and [license directory](Licenses/).

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
