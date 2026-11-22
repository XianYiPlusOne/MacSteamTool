<p align="center">
  <img src="Resources/AppIcon.png" width="112" height="112" alt="MacSteamTool's indigo gamepad icon">
</p>

<h1 align="center">MacSteamTool</h1>

<p align="center"><strong>English</strong> · <a href="README.zh-CN.md" hreflang="zh-CN">Simplified Chinese</a></p>

<p align="center">
  Manage your local Steam library, Windows game runtimes, and saves on macOS.<br>
  <sub>Apple Silicon · SwiftUI · AGPL-3.0</sub>
</p>

> [!IMPORTANT]
> **MacSteamTool is a vibe coding project.** We develop it with AI assistance, and many features have yet to be tested in detail. Coverage is limited across games, Wine and CrossOver versions, and multiplayer sessions between two physical devices. Back up important saves before restoring files or resetting a game container.

## Features

| Feature | What you can do |
| --- | --- |
| Local game library | See which games are installed on this Mac and where their files are stored. |
| Wine and CrossOver | Use the setup guide to find an existing runtime and choose how to run Windows games. |
| Saves and containers | Find, back up, and restore saves by game. Keep separate containers for games that need different settings. |
| Multiplayer | Create or join a room, invite friends, and chat. The game itself needs to support LAN play or direct connections. |

## First launch

The **Getting started** guide checks whether Steam is installed. If needed, you can download Valve's official client from the guide. Once Steam is installed, the guide automatically shows the runtime choices.

- **Already have Wine or CrossOver?** The guide shows the installation path so you can select your existing copy. CrossOver requires your own activated copy.
- **Need Wine?** Select **Install Wine** to download the runtime and graphics components.
- **Just here for your library?** Select **Manage local games only** to go straight to your games.

The current build targets **Apple Silicon**. The app runs on **macOS 14 or later**. Automatic setup requires **macOS 15 or later**. Some Steam integration features modify the local client and affect ownership checks for games and DLC.

## Open-source acknowledgments

We thank the authors and contributors whose work made these features possible.

| Project | Contribution to MacSteamTool |
| --- | --- |
| **NotProton** | Provided the basis for the Windows game runner, CrossOver integration, and game container management. Thanks to [NotProtonNot](https://github.com/NotProtonNot/NotProton) and to [Drustburn](https://github.com/Drustburn/NotProton) for the Wine launcher fork. |
| **macSteam Config (macSteam)** | Provided the local Steam configuration format and native components. Thanks to crghofficial and the macSteam contributors. [Upstream license](Licenses/macSteam.txt) |
| **OpenSteamTool** | Served as a compatibility reference for Steam message formats and how friends' game activity is displayed. Thanks to OpenSteam001 and the project contributors. [Upstream license](https://github.com/OpenSteam001/OpenSteamTool/blob/main/LICENSE) |
| **Fluent-Steam-Lua** | Informed the Lua manifest format and the workflow for managing manifests. Thanks to huanyuejue and the project contributors. [Upstream license](Licenses/Fluent-Steam-Lua.txt) |
| **ConnectTool (connecttool-qt)** | Provided the multiplayer room protocol and virtual LAN components. The Mac app implements session handling in Swift and targets compatibility with ConnectTool 1.6.0. Thanks to Ji Fuyao and the [ConnectTool contributors](https://github.com/moeleak/connecttool-qt). |

MacSteamTool uses the [GNU AGPL-3.0 license](LICENSE). For third-party authors, sources, modifications, and license terms, see the [third-party notices](THIRD-PARTY-NOTICES.md) and [license directory](Licenses/).

## Disclaimer

This project is provided for research and educational purposes only. You are responsible for complying with local laws, platform terms of service, and software licenses.
