<p align="center">
  <img src="Resources/AppIcon.png" width="112" height="112" alt="MacSteamTool 靛蓝色游戏手柄图标">
</p>

<h1 align="center">MacSteamTool</h1>

<p align="center"><a href="README.md" hreflang="en">English</a> · <strong>简体中文</strong></p>

<p align="center">
  在 Mac 上搜索游戏并加入 Steam 游戏库，用 Wine 或 CrossOver 运行兼容的 Windows 游戏，也可以通过 Steam 与好友组建联机房间。<br>
  <sub>通用 arm64/x86_64 · SwiftUI · AGPL-3.0</sub>
</p>

> [!IMPORTANT]
> **MacSteamTool 是一个 vibe coding 项目。** 我们在 AI 辅助下开发和迭代，很多功能尚未经过详细测试。尤其是不同游戏与 Wine、CrossOver 版本的组合，以及两台真实设备之间的联机，实际表现可能不同。尝试存档恢复或容器重置前，请先备份重要存档。

## 搜索游戏、入库与管理清单

- **搜索入库**支持按游戏名称或 Steam AppID 搜索，也可以从小黑盒热门榜单发现游戏。结果会标出 macOS 和 Windows 平台。「一键入库」会核对主游戏、可选 DLC 和对应的内容仓库（Depot），列出仍缺的内容。检查通过后会把条目加入游戏库。授权、安装和下载由 Steam 处理。
- **游戏库**会合并显示 Steam 已安装游戏和导入的条目。可以拖入 Lua 清单或清单压缩包，按名称、AppID 或安装状态筛选，批量启用或禁用导入条目，也可以把当前列表的清单导出为 ZIP。游戏详情页可编辑 Lua，并对照 Steam 公布的 DLC 和 Depot 数据。
- **清单管理**按游戏列出本机缓存的 Manifest 文件，可按 DepotID 和 ManifestID 获取缺失文件，也可监听已启用游戏的新清单请求。下载的文件通过格式和 CRC 校验后才会写入缓存。

## 在 Mac 上运行 Windows 游戏

- **运行器与容器**。可将 MacSteamTool Wine 或已激活的 CrossOver 设为默认运行器，再按游戏调整。需要测试不同配置时，可为同一游戏创建多个独立容器，在其中运行 EXE 或 MSI、查看日志，也可备份和恢复整个容器。
- **离线工具（实验性）**。为选定的 Windows 游戏生成离线启动配置，预览将新增或替换的文件，备份后部署。部署记录可用于检查补丁是否加载，以及还原文件。

## 联机、成就与存档

- **好友联机**。通过 Steam 网络创建或加入房间、浏览公开大厅、邀请好友和聊天。支持 TCP 转发和 TUN 虚拟局域网，兼容目标为 Windows 版 ConnectTool 1.6.0。双方游戏版本需兼容，游戏需支持局域网或直连。首次启用 TUN 需要管理员授权。
- **成就与游玩时长**。按游戏读取成就进度，筛选、解锁或重新锁定成就。对于使用兼容成就的游戏，编辑结果保存到兼容记录。可以按 AppID 开启成就与统计同步、记录游玩时长。
- **本地存档与备份**。按游戏查找存档，也可手动关联自定义目录。备份会逐文件校验，恢复前会保留当前存档的回退副本。重新安装游戏后可以找回已有备份。游戏自身的 Steam 云存档由 Steam 管理。
- **账号与好友状态**。在 Steam 已记住的账号之间切换并启动客户端，也可以设置好友是否能看到所选游戏的游玩状态。

在「设置」中还可以管理下载源与缓存，通过 HTTPS 更新源检查更新，或导入本地签名更新包。应用会在安装前验证更新包，并保留上一版本。

## 第一次打开

「使用指南」会先检查这台 Mac 是否安装了 Steam。如果还没有，可以在指南中下载 Valve 官方客户端。安装完成后会自动显示运行环境选项。

- **已有 Wine 或 CrossOver**　指南会显示检测到的安装路径，可直接选用。CrossOver 使用你自己已激活的副本。
- **需要 Wine**　选择「安装 Wine」后会联网下载运行器和图形组件。
- **先看看游戏库**　选择「仅管理本机游戏」可跳过运行器配置。之后仍可从侧栏打开「搜索入库」「清单管理」或「运行环境」。

在 Apple 芯片 Mac 上，以 Intel 或 ARM 模式运行的 MacSteamTool 都可以打开已安装的 Intel、ARM 或通用版 Steam。macOS 按 Steam 自身的设置选择运行架构。可在「运行环境 → 诊断与恢复」查看 Steam 包含的架构和当前进程使用的架构。

应用、原生库和安装恢复助手 `MacSteamToolNotProton` 均以 **通用 arm64/x86_64** 构建。助手可在 Intel 上执行安装、备份和恢复；CrossOver 接入仅注册可用的 x86_64 运行器，不注册 ARM FEX。现已包含 Steam 构建 `1794536281` 的 Intel `macSteam` 和 `NotProton` 适配数据，支持兼容工具注册、列表和选择运行器所需的接口；未知构建不会套用旧地址。当前已完成 Apple 芯片主机上的 x86_64 隔离测试，仍需实体 Intel Mac 验收完整游戏启动。NotProton 的 Intel 指令补丁不支持 Rosetta 翻译进程；Apple 芯片请使用原生 ARM Steam。原生接入另有版本和架构要求。例如，纯 Intel 客户端需要对应 Steam 构建的 `macos.x86_64` 适配数据，自动安装还会检查 MacSteamTool 当前架构的适配数据。应用最低启动版本为 **macOS 14**，自动初始化需要 **macOS 15 或更新版本**。部分 Steam 接入功能会修改本机客户端，并影响游戏和 DLC 的所有权检查。

## 从源码构建

完整构建流程见[构建指南](BUILDING.zh-CN.md)。从全新克隆开始，先运行 `./script/bootstrap_build_env.sh --check`，再运行 `./script/build_and_run.sh --build`。构建过程只会把已固定版本并经过校验的上游依赖下载到被忽略的 `work/` 和 SwiftPM 构建目录；生成的发布文件统一放在 `outputs/`，不会提交到 Git。

## 开源鸣谢

感谢以下项目的作者和贡献者。MacSteamTool 的多项功能来自他们公开的工作。

| 项目 | 在 MacSteamTool 中的贡献 |
| --- | --- |
| **[NotProton](https://github.com/NotProtonNot/NotProton)** | Windows 游戏运行器、CrossOver 接入和游戏容器管理的移植基础。感谢 [NotProtonNot](https://github.com/NotProtonNot/NotProton) 和维护 Wine 启动器分支的 [Drustburn](https://github.com/Drustburn/NotProton)。 |
| **[macSteam Config（macSteam）](https://github.com/crghofficial/macsteam)** | 本机 Steam 配置格式和原生组件的来源。感谢 crghofficial 及 macSteam 贡献者。[上游许可](Licenses/macSteam.txt) |
| **[OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool)** | Steam 消息格式和好友游戏状态的兼容性参考。感谢 OpenSteam001 及项目贡献者。[上游许可](https://github.com/OpenSteam001/OpenSteamTool/blob/main/LICENSE) |
| **[Fluent-Steam-Lua](https://github.com/huanyuejue/Fluent-Steam-Lua)** | Lua 清单格式与清单管理流程的参考。感谢 huanyuejue 及项目贡献者。[上游许可](Licenses/Fluent-Steam-Lua.txt) |
| **[ConnectTool（connecttool-qt）](https://github.com/moeleak/connecttool-qt)** | 联机房间协议和虚拟局域网组件的来源。Mac 端使用 Swift 实现会话逻辑，兼容目标为 ConnectTool 1.6.0。感谢 Ji Fuyao 及 [ConnectTool 贡献者](https://github.com/moeleak/connecttool-qt)。 |

MacSteamTool 采用 [GNU AGPL-3.0](LICENSE)。第三方组件各自的作者、来源、修改记录和许可见[第三方声明](THIRD-PARTY-NOTICES.md)与[许可证目录](Licenses/)。

## 免责声明

本项目仅供研究和教育之用。你有责任遵守当地法律、平台服务条款和软件许可协议。
