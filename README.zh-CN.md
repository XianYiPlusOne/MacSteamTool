<p align="center">
  <img src="Resources/AppIcon.png" width="112" height="112" alt="MacSteamTool 靛蓝色游戏手柄图标">
</p>

<h1 align="center">MacSteamTool</h1>

<p align="center"><a href="README.md" hreflang="en">English</a> · <strong>简体中文</strong></p>

<p align="center">
  在 Mac 上管理本机 Steam 游戏、Windows 游戏运行环境和存档。<br>
  <sub>Apple Silicon · SwiftUI · AGPL-3.0</sub>
</p>

> [!IMPORTANT]
> **MacSteamTool 是一个 vibe coding 项目。** 我们在 AI 辅助下开发和迭代，很多功能尚未经过详细测试。尤其是不同游戏与 Wine、CrossOver 版本的组合，以及两台真实设备之间的联机，实际表现可能不同。尝试存档恢复或容器重置前，请先备份重要存档。

## 可以用它做什么

| 功能 | 使用场景 |
| --- | --- |
| 本机游戏库 | 在一个窗口查看游戏、安装位置和本地安装状态。 |
| Wine 与 CrossOver | 在「使用指南」里查看这台 Mac 已有的运行器，按需为 Windows 游戏选择运行环境。 |
| 存档与容器 | 按游戏查找、备份和恢复本地存档，为需要不同配置的游戏管理独立容器。 |
| 好友联机 | 在「联机」页创建或加入房间、邀请好友、发送消息。游戏本身需要支持对应的局域网或直连玩法。 |

## 第一次打开

「使用指南」会先检查这台 Mac 是否安装了 Steam。如果还没有，可以在指南中下载 Valve 官方客户端。安装完成后会自动显示运行环境选项。

- **已有 Wine 或 CrossOver**　指南会显示检测到的安装路径，可直接选用。CrossOver 使用你自己已激活的副本。
- **需要 Wine**　选择「安装 Wine」后会联网下载运行器和图形组件。
- **只想整理游戏**　选择「仅管理本机游戏」即可进入游戏库。

当前构建面向 **Apple Silicon**。应用最低启动版本为 **macOS 14**，自动初始化需要 **macOS 15 或更新版本**。部分 Steam 接入功能会修改本机客户端，并影响游戏和 DLC 的所有权检查。

## 开源鸣谢

感谢以下项目的作者和贡献者。MacSteamTool 的多项功能来自他们公开的工作。

| 项目 | 在 MacSteamTool 中的贡献 |
| --- | --- |
| **NotProton** | Windows 游戏运行器、CrossOver 接入和游戏容器管理的移植基础。感谢 [NotProtonNot](https://github.com/NotProtonNot/NotProton) 和维护 Wine 启动器分支的 [Drustburn](https://github.com/Drustburn/NotProton)。 |
| **macSteam Config（macSteam）** | 本机 Steam 配置格式和原生组件的来源。感谢 crghofficial 及 macSteam 贡献者。[上游许可](Licenses/macSteam.txt) |
| **OpenSteamTool** | Steam 消息格式和好友游戏状态的兼容性参考。感谢 OpenSteam001 及项目贡献者。[上游许可](https://github.com/OpenSteam001/OpenSteamTool/blob/main/LICENSE) |
| **Fluent-Steam-Lua** | Lua 清单格式与清单管理流程的参考。感谢 huanyuejue 及项目贡献者。[上游许可](Licenses/Fluent-Steam-Lua.txt) |
| **ConnectTool（connecttool-qt）** | 联机房间协议和虚拟局域网组件的来源。Mac 端使用 Swift 实现会话逻辑，兼容目标为 ConnectTool 1.6.0。感谢 Ji Fuyao 及 [ConnectTool 贡献者](https://github.com/moeleak/connecttool-qt)。 |

MacSteamTool 采用 [GNU AGPL-3.0](LICENSE)。第三方组件各自的作者、来源、修改记录和许可见[第三方声明](THIRD-PARTY-NOTICES.md)与[许可证目录](Licenses/)。

## 免责声明

本项目仅供研究和教育之用。你有责任遵守当地法律、平台服务条款和软件许可协议。
