# steamplay-mac 路线验证（2026-11-11）

## 结论与边界

**可以继续推进“原生 Mac Steam + 独立免费 Wine 运行器”的整合。当前已验证运行器、GPU 渲染及 Windows → 原生 Mac Steam API 链路；尚未验证完整的 Steam 点击开始流程，也尚未把此运行器接入 Fluent 的产品界面。**

本轮没有运行上游安装器，没有更换 Steam 内的内核，没有调用已购买的 CrossOver 程序或其克隆运行器。原生 Steam 保持运行，仍加载本机原有的 macSteam、NotProton 等扩展。因此这里的成功不能解读为“steamplay-mac 整套旧版内核已经替换了现用 NotProton”。

本轮验证的是上游预构建发布包。另行验证了公开源码下载、源码摘要、22 项补丁应用和 lsteamclient 源码摘要；**没有完成从源码重建整个 Wine 的验收**。

## 固定输入

| 项目 | 本轮使用 |
| --- | --- |
| Mac | Apple M4 Pro，arm64 |
| macOS | 27.0.1，build 26A434 |
| 原生 Steam | build 1792618285 |
| steamplay-mac | `e350a87013fcbd4c81c33b59e8081f943b271955`，tag `v2026.10.13` |
| 其 NotProton 子模块 | `df2f23a71bd42151e9aec923b1a01e50efcb8505` |
| 发布包 | `steamplay-mac-2026.10.13-e350a87.dmg` |
| 发布包 SHA-256 | `4d2446faa89f8c72838ca419df5b76d76a8d9ac52bea11cb47dd731ea83f85a8`，已匹配官方发布说明 |
| 运行器 | `selfbuilt-cx26.3-r2`，Wine 11.0，CrossOver 26.3 开源部分构建，x86_64 / Rosetta |
| 图形后端 | DXMT v0.80、D3DMetal 3.0；未测试 GPTK 4 |
| 实游戏 | 已安装 ForgeTax（5245810）的隔离文件副本 |

上游：[源码与说明](https://github.com/Drustburn/steamplay-mac/tree/e350a87013fcbd4c81c33b59e8081f943b271955)、[发布包与摘要](https://github.com/Drustburn/steamplay-mac/releases/tag/v2026.10.13)、[CodeWeavers 开源部分源码](https://www.codeweavers.com/crossover/source)。

## 本机验证结果

| 检查 | 结果 | 能证明什么 |
| --- | --- | --- |
| 发布包 SHA-256 与只读磁盘镜像校验 | 通过 | 实测文件对应固定发布包 |
| 独立 Wine 启动、独立 prefix 初始化、Windows 命令 | 通过 | 免费运行器可在本机执行 Windows 程序 |
| DXMT / D3D11 | GPU 清屏、复制到 staging、CPU 回读通过，RGBA `255,0,0,255` | 实际 GPU 路径执行成功，非仅创建 device |
| D3DMetal / D3D11 | 同样回读通过 | 第二种 D3D11 后端可用 |
| D3DMetal / D3D12 | command queue、render target、resource barrier、copy、fence 与回读通过，RGBA `0,255,0,255` | D3D12 基础图形路径可用 |
| Windows Steam API → Mac Steam | `SteamAPI_InitFlat=0`，AppID `5245810`，`logged_on=1` | Windows API 与当前运行的原生 Mac Steam 连接成功 |
| 加载模块检查 | 发现隔离运行器的 `lsteamclient.so`、图形模块及本机原生 `steamclient.dylib`；未发现商业 CrossOver / 现有付费运行器路径 | 本次执行链使用独立运行器 |
| ForgeTax / DXMT | Unity 图形初始化完成，游戏日志报告 Steam Online / Connected | 实游戏的启动与 Steam 连接可行；不代表完整游玩验收 |
| ForgeTax 强制 DX12 / D3DMetal | **回退至 DX11**：`failed to create D3D11On12 device (0x887a0004)` | 不能把此游戏记为 DX12 成功；底层探针通过不等于所有 DX12 游戏兼容 |
| ForgeTax 画面人工确认 | 用户于 2026-11-11 回复“能看到正常游戏画面” | 隔离测试的游戏画面已获人工确认；反馈未区分具体后端 |
| 上游 `compatcheck`、`compatsvc-check` | 通过 | 上游兼容工具布局、服务处理和状态逻辑的测试通过 |
| 上游 `anchorcheck` 对当前 Steam | **完整测试退出 1**，三个旧库的 17 个 anchor 均找到；记录地址、vptr 和回退模式的校验有失败 | 旧版特征库不能直接当成本机完整兼容性验收；没有部署这个旧内核 |

画面验收补充（2026-11-11）：用户对隔离测试明确回复“能看到正常游戏画面”，因此游戏画面已获人工确认。CUA 两次无法附着到 Wine 子进程窗口，仍无自动截图证据。用户反馈未区分 DXMT 与 D3DMetal 轮次，不将其解读为各后端分别通过或 DX12 游戏成功；强制 DX12 回退至 DX11 的日志结论保持不变。

成就限制：游戏日志中的接口状态为 Connected，但同时出现 `readable=0/19`。本轮不宣称成就解锁/回读/同步通过。验证程序只读取 AppID 和登录状态，没有调用成就写入或云存档写入接口。

尚未验收：原生 Steam 的安装按钮→启动按钮→退出/停止全流程、覆盖层交互、云存档读写/同步、控制器、32 位游戏、长期稳定性、跨版本升级及全部现有扩展的组合回归。

## 如何做到一个程序管理

目标链路：

```text
Fluent Steam Mac
  ├─ 内置安装/更新/修复助手
  ├─ 管理 macSteam 内核和配置
  ├─ 管理与当前 Steam 匹配的 NotProton 桥接内核
  └─ 管理版本化运行器
       ├─ 免费 Wine + DXMT / 可选 D3DMetal
       └─ 用户已有的 CrossOver（可选）

原生 Mac Steam → 兼容工具入口 → 独立 Wine → Windows 游戏
                                  └→ lsteamclient → 原生 Mac Steam API
```

单一程序入口在技术上可行。官方 Steam 仍是客户端；体积约 1 GiB 的解压运行器更适合由程序下载、校验并按版本管理，不必让用户安装多个管理界面，也不必把全部资源塞进主 app。

### 不直接照搬上游安装脚本

核对 `scripts/install.sh` 后发现：

1. `cmd_steam` 遇到已有其他 `DYLD_INSERT_LIBRARIES` 时拒绝安装。本机正在使用 macSteam、Fluent Manifest、CloudRedirect 和 NotProton，正好触发该情况。
2. `cmd_support` 共用 `~/Library/Application Support/notproton/bridge`，且删除旧 `bridge/wine`。直接使用会破坏当前付费运行器的桥接布局。
3. `cmd_uninstall` 删除整个 NotProton 支持目录，不能用于多运行器共存的产品。
4. 默认有阻止 Steam 更新的安装步骤，产品应当按明确的兼容策略处理，不应直接继承为默认行为。

因此应复用 Fluent 现有的事务备份、摘要校验、原子替换和恢复机制，并为免费运行器与桥接资源设置独立目录。

### 当前代码需要的适配

| 位置 | 当前绑定 | 所需改动 |
| --- | --- | --- |
| `Sources/FluentCore/Runtime.swift` | 只枚举 `runners/*/CrossOver`；`WineLaunch` 根据 `notproton-build` 找 CrossOver | 引入运行器描述：类型、版本、loader、server、架构、后端、bridge、prefix 格式；按描述启动 |
| `Engine/NotProtonInstaller/.../InstallSession.swift`、`Adapter.swift` | 校验官方 companion app，并将其登记为 prefix 重建入口 | 从我们自己的 payload 获取组件；由自带助手负责重建和修复 |
| `Engine/NotProtonInstaller/.../KernelSession.swift` | macSteam 资源来自外部 companion app | 增加已校验的内部资源入口，沿用现有部署事务 |
| `Sources/FluentCore/OfficialRuntimeUpdates.swift` | 仅支持现有两种官方 app 发布包 | 增加独立的运行器版本清单、摘要、兼容范围及更新回滚 |
| `Native/NotProton` / 现用 NotProton 分支 | 已有当前版本修复及多个运行器功能 | 优先把 self-built runner 的支持移入现用分支，保留本机已有修复；不要整体降级为 10 月旧 fork |
| 游戏 prefix | 各运行器的 Wine/桥接内容不同 | 初次验证使用独立 prefix；迁移时显式备份存档，不能直接用新 Wine 重写现用 prefix |

CrossOver 的现有授权验证仍属于付费后端。免费后端使用独立构建产物，不通过删除付费后端的授权检查实现。

### 构建及发布仍需处理

- 干净 checkout 的 `build-all.sh` 先执行 `build-deps.sh`，但后者要读取 `sources/sources/gnutls/gmp` 等目录；这些目录由排在后面的 `prepare-wine-src.sh` 创建。完整构建入口需先准备源码再构建依赖。本轮已显式先准备源码，但尚未跑完整 Wine 编译。
- 实测发布包的 DLL/资源布局可运行，不代表它已经达到我们的可重现构建、签名和公证标准。
- macSteam、NotProton、Wine、lsteamclient、Valve DLL 和 Apple 图形组件分别处理许可及来源。上游“不把 Apple/Valve 文件放进 DMG”是一种分发设计，不能作为我们已经获得所有组件再分发权的依据。正式出包前应核对各组件适用条款；本轮只做本机验证。

## 复现

前提：Apple Silicon、Rosetta、Command Line Tools、Git、Python 3.11+、`mingw-w64`（本轮通过 Homebrew 安装）。不需要商业 CrossOver，也不需要运行 NotProton 的管理界面。

```sh
./script/prepare_steamplay_validation.sh
python3 script/validate_steamplay.py --only graphics
python3 script/validate_steamplay.py --only steam \
  --steam-api '/绝对路径/某个已安装游戏/steam_api64.dll' --app-id 对应AppID
```

Steam API 检查要求原生 Steam 已登录。`prepare` 不调用上游 `install.sh`，不改 Steam.app，不运行自动更新阻止步骤。验证器只终止自己的 `work/steamplay-validation/acceptance/pfx`，不要在这个验证 prefix 内放需要保留的游戏会话。

所有下载、运行器、游戏副本、临时 prefix、模块清单和日志均在被 Git 忽略的 `work/steamplay-validation/`。主产品没有新增 Wine、Apple 或 Valve 二进制。

证据文件（相对项目根目录）：

- `work/steamplay-validation/acceptance/results-all.json`：最终的完整基础验证。
- `work/steamplay-validation/acceptance/*.result.txt`：Windows 探针自行写出的结果，避免 steam.exe 子进程退出 0 被误判为 API 成功。
- `work/steamplay-validation/acceptance/dx11-ForgeTax-Player.log`：DXMT 实游戏启动日志。
- `work/steamplay-validation/acceptance/ForgeTax-DX12-Player.log`：强制 DX12 回退到 DX11 的日志。
- `work/steamplay-validation/acceptance/dx11-game-evidence.json`、`dx12-game-evidence.json`：实游戏加载模块。
- `work/steamplay-validation/bridge-checks.log`、`upstream/anchor-current-steam.log`：桥接层检查及未通过的完整 anchorcheck。
- `work/steamplay-validation/prepare.log`：公开源码及 22 项补丁准备结果。
- `work/steamplay-validation/live-baseline.json`：运行前对 Steam 配置和已部署扩展的摘要记录。最终验证器逐项回查。

最终完整验证共 5 项通过，各图形/Steam 测试均观察到要求的实际模块。8 项现用配置/扩展文件摘要回查一致；原生 Steam 仍为测试前的 PID 2636。

本轮实游戏为启动观察，不进行游玩进度验收。独立测试进程已在结束时清理；现用 Steam 不需要重启或恢复。
