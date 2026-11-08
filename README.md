# Fluent Steam Mac

原生 macOS Steam Lua 管理器，适配 **macSteam 0.8.2 配置格式**及 **NotProton 的原生 Steam / CrossOver 前缀布局**。SwiftUI + C++ 原生桥接 + Swift Package Manager，macOS 14+，本次产物为 Apple Silicon。

**当前是 0.2.9 开发版，尚未完成完整复刻验收。** 已补签名更新、反馈报告、下载偏好、离线库存与原生 Manifest Provider；实际测试范围和剩余项见下表。不能把编译成功、检测到动态库或通过文件测试当成所有游戏已兼容。

## 运行

打开 `outputs/Fluent Steam Mac.app`。开发时执行：

```sh
./script/build_and_run.sh --verify
./script/test.sh
python3 script/test_worker.py
```

Codex 的 Run 按钮也已配置。`--build` 仅打包，`--debug` 启动 lldb，`--logs` 查看运行日志。首次构建需要 CMake，并通过网络恢复 ZIPFoundation 0.9.20、SteamKit2 3.4.0、固定版本的 Dobby、.NET 8 macOS ARM64 / Windows x86 运行时和 CPython Windows 运行时。打包后不需要用户安装 .NET。应用采用本机临时签名，没有 Apple 开发者公证。

## 使用

1. 在“运行环境”确认 Steam 数据目录、macSteam 和 NotProton 已安装。可检查和下载官方 macSteam/NotProton，校验摘要、签名及当前 Steam 兼容数据；也可选择本机官方 companion app，提供备份安装、更新、内核卸载和恢复。内核操作要求 macOS 15+ 且 Steam / Wine 工具已退出。
2. 拖入 Lua / ZIP / TAR / 7z / RAR，或使用“搜索入库”。预览中可查看 DLC、密钥缺失、覆盖文件和 macSteam 不支持的语句。
3. 点击“导入并启用”。原始 Lua 保留，支持的部分转换为 macSteam `config.yaml`。重启 Steam 后检查游戏库。
4. Windows 游戏继续由 Steam 中所选的 NotProton 兼容工具运行。详情页可打开对应前缀、Wine 配置和日志。
5. 修改器下载后需解压，填写 AppID，绑定 `.exe`。选择游戏的实际 .exe 后可监控进程、自动启动修改器、延迟发送选定快捷键，并在游戏退出时清理本次启动的修改器。快捷键只发给前台游戏或修改器。

## 实现范围

| 原项目功能 | 本版本 |
| --- | --- |
| 游戏库、中文名称、封面、三种布局、过滤 | 已实现 |
| Lua/ZIP/TAR/7z/RAR 导入，Lua/Manifest/Bin 导出，拖放 | 已实现；限量解压、拒绝路径穿越/链接/同名不同内容文件；TAR、solid 7z、RAR4 完整导入/还原通过 |
| macSteam 已有游戏读取、入库、启用、禁用、移除 | 已实现；保留未知根配置段；失败回滚 |
| 名称/AppID 搜索、depot 密钥生成清单 | 已实现；依赖第三方内容源，缺失密钥明确报告 |
| 创意工坊下载密钥 | 生成清单时保留 AppID 仓库密钥；已有游戏可备份补齐；Probably Stolen 的 14 个既有订阅 Mod 实际下载通过，游戏内加载尚未测试 |
| DLC 查询与补全 | 已实现；DLC depot 缺少全部密钥时跳过并提示 |
| 本地安装、外置库、NotProton 前缀识别 | 已实现 |
| Steam 启动/重启、本地账号切换 | 已实现；账号切换要求 Steam 退出并已保存登录 |
| 修改器搜索/下载/绑定/Wine 运行 | 已实现进程监控、生命周期与快捷键激活；隔离 NotProton 测试通过，实际游戏修改效果未验证 |
| 手动 / 自动监听 Manifest 下载 | 已实现；新日志请求去重、日志轮转、多个 HTTPS 源与 Steam CDN 切换，验证分段 / DepotID / ManifestID / CRC |
| 版本锁定 | 新增 Fluent Manifest 原生扩展；真实 ARM64 Steam 函数隔离验证通过，支持 build 1792618285 的 public 分支、有效缓存和热加载；实际 Steam 下载/更新待测试 |
| 内核安装/更新/卸载 | 从本机官方资源内置备份部署、更新、内核卸载、校验恢复及中断恢复（先保留当前完整状态）；macSteam / NotProton 实机安装、更新、卸载、运行器清理和完整恢复通过；保留游戏前缀 |
| 本地存档和配置备份 / 恢复 / 清空 | 已实现；恢复或清空前另建经过校验的当前存档副本 |
| CloudRedirect 云存档 API 重定向、迁移 | macOS ARM64 原生 RPC/HTTP/路径适配、7 种服务商配置和回读校验迁移已实现；独立真实 Steam dylib 测试通过；480 的 NotProton 实际 API 上传、云端重新下载和删除通过；完整游戏及在线服务商待验证 |
| SteamKit 在线登录并提取正版 Lua/密钥 | 已接入扫码、钥匙串、账号库、DLC 子仓库和批量 Lua/Manifest，可选本地成就定义 Bin；匿名连接通过，已登录账号端到端测试等待用户扫码 |
| 成就编辑与写回 | 原生 Steam 模式保留回调验证；新增公开定义初始化和当前账号兼容记录。已安装 4348910 的 21 项读取、原生及 NotProton 单项解锁/还原通过；兼容保存不代表 Valve 服务器接受 |
| Denuvo appticket / eticket 提取和使用 | 双票据提取、原版文本/文件导入、账号绑定消费和真实异步回调已实现；480 原生 Steam 与 NotProton Windows 接口消费通过；Denuvo 游戏未验证 |
| 480 / OnlineFix 补丁搜索部署 | 搜索/下载、ZIP/RAR/7z、安全预览、备份部署/恢复、按游戏 DLL 覆盖已接入；原站实测 HTTP 403，实际联机待测 |
| SteamStub 去除、Goldberg 部署/还原 | 已接入独立 Windows x86 助手、官方工具下载/校验、PE 副本处理、Goldberg 双架构配置与事务恢复；合成 SteamStub 3.1 和真实 Goldberg DLL 隔离测试通过 |
| 好友游玩状态广播 | 0.2.6按原项目采用非Steam快捷方式优先、Spacewar回退，处理最近启动游戏；当前账号范围、语言标题及两种发送身份的真实Steam二进制隔离测试通过；好友端通知仍待实测。 |
| 云成就、统计和游戏时长 | 已实现独立 AppID 列表、账号隔离、云端合并、失败重试、统计回锁与实时刷新；本地文件夹服务商实测通过，在线服务商和跨设备实测待验证 |
| Manifest 源内核热切换 | 已实现 macSteam / Steam / 自定义 HTTPS，按 AppID 约每秒加载；真实 macSteam 处理函数隔离验证通过，实际游戏下载待验证 |
| 深浅主题、语言、文件监控 | 支持；核心错误与导入警告已补双语说明 |
| 菜单栏常驻、主窗口恢复、后台监听 | 已实现 |
| 自动更新、反馈、下载偏好 | 可配置签名 HTTPS 源、启动检查、本地包导入、原子安装与旧版备份；报告预览/导出、镜像测速、Steam CDN 偏好已实现；暂无公共发布地址 |
| Lua addtoken | 已接入 FluentAccessTokens 与原生 PICS 请求消费；真实 Steam typed protobuf / Send 钩子隔离验证、UInt64 精度和热禁用通过；真实 CM 获取需有效令牌回归 |
| Goldberg 离线库存 | 支持库存定义 JSON 导入、Steam 定义查询及双架构配置；查询需可用 API 权限，实际游戏库存待验证 |

## 数据位置和写入方式

- 配置、Lua、缓存和事务备份：`~/Library/Application Support/FluentSteamMac/`
- macSteam：`~/Library/Application Support/macsteam/config.yaml`
- Steam：`~/Library/Application Support/Steam/`
- NotProton：`~/Library/Application Support/notproton/`
- 可在设置里指定其他目录；更改目录不会自动迁移旧文件。

启动应用读取现有 Steam/macSteam 文件，并可获取名称缓存；自动广播模式还会备份并同步已启用主游戏的名称注释。实际导入、禁用、账号切换等由用户在界面中发起。所有受管文件修改先保存备份及 SHA-256，再原子替换；批次失败回滚。写入 macSteam 配置前检查文件是否被其他应用修改。现有 macSteam 内核限制 256 个 depot key 组、每组 64 个 depot，超限会拒绝写入而不是静默截断。

不会读取密码、发送登录凭证或执行导入的 Lua。macSteam 会重新加载配置，但 Steam 游戏库状态可能需要重启才能同步。

## 测试

使用 Swift Testing（`./script/test.sh` 自动适配 Command Line Tools 的宏插件路径）。`Tests/FluentCoreTests` 覆盖 Lua 注释/密钥/归属、VDF、未知配置保留、导入→禁用→启用→ZIP 导出→恢复、并发配置冲突、批次失败回滚、恶意 ZIP、备份篡改、外置 Steam 库、存档备份、账号切换。测试只使用临时目录。

当前核心测试涵盖新增补丁事务、Wine 注册表与离线工具流程，包括 Manifest 二进制格式 / 身份 / CRC、日志半行 / 去重 / 轮转、存档恢复 / 清空与备份完整性、配置恢复路径中的符号链接逃逸。

`script/test_worker.py` 编译测试用 `steamclient.dylib`，验证真实成就 worker 的 15 个隔离场景，不连接真实 Steam：读取、解锁、回锁、AppID 不匹配、读取后状态冲突、服务端拒绝保存、异常数量、未知成就。原生接口因客户端更新可能变化；进程崩溃或超时会返回错误。普通 Steam 模式只在收到 `UserStatsStored_t` 成功回调后报告成功；显式兼容模式还要求当前运行扩展、配置摘要及账号范围匹配，并独立核对重新读取的状态和持久化记录。

真实网络验证通过 Steam 搜索、详情、depot 查询和 Portal 2 的 `621_9044256803759256265.manifest` 下载（1,188,437 字节），验证分段、身份和内容 CRC；未写入真实 Steam 目录。默认 SDM 源当时 TLS 失败，自动切换后成功。第三方源不能保证持续可用。

原项目参考版本固定为 **Fluent-Steam-Lua 1.5.4.2 / 93d86eb**。这些文件级测试不能替代已登录 Steam、实际下载游戏、游戏成就/云端变化和多版本 Wine 的端到端验证。

## 继续实现完整复刻所需的工作

1. 完成版本锁定的真实 Steam 下载回归、好友端广播显示和受保护游戏票据兼容测试；验证已实现的 Manifest provider 切换和下载路径。
2. 完成全游戏云同步、在线服务商和多设备统计/游戏时长回归；现有原生 API、独立文件夹同步和显式 AppID 隔离已有测试证据。
3. 完成已实现 SteamKit 在线提取的已登录账号验证（用户暂缓扫码）。
4. 对已接入的 SteamStub / Goldberg / OnlineFix 工具链执行实际 Windows 游戏回归，包括更多 SteamStub 变体、修改器快捷键和联机。
5. 发布 HTTPS 更新源后验证线上分发，并完成实际游戏回归。签名更新和本地安装已实现；核心错误与导入警告已补双语说明。

这些包括需要账号、游戏、第二台设备和发布服务器的验收项；已接入的功能不等于所有环境都已实测通过。

## 许可证

AGPL-3.0。此项目为独立修改/移植版本。原项目和依赖署名见 THIRD-PARTY-NOTICES.md 与 Licenses/。

### 本轮新增验证（2026-11-05）

- `script/test_cloud.py`：两个独立本地服务商根目录，二进制与空文件复制、回读验证、重复执行、冲突保留与源数据不变，全部通过。
- `script/test_cloud_oauth.py`：Google Drive / OneDrive PKCE、仅回环监听、错误 state 拒绝、用户取消及凭证文件权限通过；没有登录云账号，也没有请求服务商 token。
- `Native/CloudRedirect/tests/native_probe.cpp`：加载实际 ARM64 `steamclient.dylib`，验证 Mach-O vtable 安装、真实 protobuf 请求响应、480 接管/481 透传、本地 HTTP 文件上传下载、路径穿越拒绝、外置库 NotProton 路径与正常卸载；不连接 Steam IPC、不访问真实存档。
- 已安装的 NotProton 26.3.0.39832 在独立前缀运行 Windows x64 Python 探针，成功通过 `steamclient64.dll` / SteamClient018 / SteamUserStats012 读取 Spacewar 480 的 5 项成就。此证据验证运行器与 Steam 桥接，不等于所有 Windows 游戏已兼容。
- 云重定向默认关闭，只接管明确选择的 AppID。统计/成就与时长默认关闭，另用独立 AppID 列表控制。当前已验证的 protobuf 配置对应 Steam build 1792618285，特征不匹配时拒绝安装 hooks。

### 新增工具与安装回归

- `script/test_wine_adapter.py` 实际使用应用的 `WineLaunch.prepare` 启动已安装 NotProton 26.3.0.39832；隔离前缀内的 DLL 注册表配置、修改器监控/清理通过，没有发送快捷键。
- `FluentNotProton --self-test` 验证共存加载配置、备份完整性、冲突拒绝、回滚和共享安装锁；`--test-kernel` 将真实 macSteam 资源部署到合成 Steam.app，再完整恢复。真实 Steam 运行时拒绝安装，现有 Steam 和游戏未被退出。
- `script/test_steamless_bridge.py` 在 NotProton 下加载官方未修改的 7 个 Steamless 插件，解包自建 SteamStub 3.1 x64 PE：恢复原入口、删除 .bind、保留代码；没有执行这个合成 PE。未加壳 PE 正确拒绝。
- `script/test_goldberg_windows.py` 加载真实 Goldberg x64 DLL，只在隔离前缀的临时 AppID 480 中验证初始化、AppID、成就定义及本地解锁/回锁，未写真实 Steam 成就。
- 工具下载只使用官方发布文件，Steamless 固定 SHA-256，Goldberg 使用 GitHub 提供的 SHA-256。原始工具压缩包保留在用户缓存中，未加入本应用分发包。

### Manifest 原生扩展

运行环境可安装 `Fluent Manifest`。启用 Lua 的 `setManifestid` 同步为 macSteam YAML 中的 `FluentManifestPins`，禁用/移除游戏时一并移除；旧 Lua 可点击“同步已有 Lua 锁定与令牌”。扩展约每秒刷新，经分段、身份及 CRC 校验的缓存 Manifest 才参与 public 分支版本选择。请先在清单管理下载对应版本。只支持 Steam ARM64 build `1792618285`；未知 Mach-O UUID、改动过的入口、Beta 分支和其他 depot 均不覆盖。正在进行的下载需要停止后重试。

原生验证命令：`python3 script/test_manifest_native.py --steam-client /absolute/path/steamclient.dylib --manifest /absolute/path/621_9044256803759256265.manifest`。测试使用独立进程和临时数据；包括真实函数锁定/取消、缓存损坏/修复、未知版本拒绝及 hook 移除。该扩展现已在真实 Steam 中与 macSteam、NotProton、CloudRedirect 同时加载；实际版本锁定下载仍待验证。

### 票据、广播、统计与时长

“Steam 账号”页提供票据导入、按账号启用消费和好友游玩状态设置；“存档与备份”页可独立启用统计/时长，存档重定向无需开启。这些功能使用同一个 `cloud_redirect.dylib` 原生扩展，安装前退出 Steam；安装会保留 macSteam、NotProton 和其他加载项并创建完整备份。

- 票据与广播设置约每秒加载；服务商、统计列表和同步开关修改后重启 Steam。
- 票据仅保存在权限 0600 的本机文件，只有相同 Steam 账号和 AppID 才会使用；界面显示当前真实 Steam PID 和消费计数。未匹配的请求透传。
- 时长按设备与平台累计，再合并至账号数据；NotProton 的 Wine 进程从消息中的 PID 识别。所选 AppID 的数据可刷新至 Steam 本地时长显示，不代表改写了 Valve 的服务端游玩记录。
- 明确回锁/重置携带持久修订号，避免旧云副本或仍运行的客户端重新解锁；新的明确成就提交仍可解锁。
- 云配置和票据默认不接管其他游戏；0.2.2 起广播默认覆盖已启用的 macSteam 主游戏，保留显式隐藏/原生选择。当前原生配置仅验证 Steam ARM64 build 1792618285 + macSteam 0.8.2，版本或入口校验失败则不安装挂钩。

`script/test_runtime_native.py` 验证真实 dylib ABI、隔离票据消费/回调、消息过滤、统计 RPC、真实一分钟累计、回锁冲突和退出清理。实机测试和限制见 `outputs/验证与未完成项.md`；测试日志不包含票据内容。

### 0.2.0 新增验证（2026-11-08）

- 实机 macSteam 和 NotProton 安装/更新/恢复往返，以及 NotProton 运行器清理/恢复通过。修复目录 URL 尾斜杠引发的恢复误判。
- LLDB 捕获 macSteam 签名扫描线程在补丁写入期间的执行权限异常；以预先准备好的 RX 页面替换原映射。两套原生扩展各完成 4,000 次补丁压力测试，同页四线程持续执行；另修复 Manifest 扩展退出时访问已销毁注册表的问题，正常进程退出回归通过。真实 Steam 重启验证见输出报告。
- 实际 NotProton Windows API 写入 480 专用二进制文件；移除两个本地测试副本后，Steam 通过本地 HTTP 从服务商重新下载，逐字节一致；FileDelete 与云清单、孤立 blob 清理通过。9 个已记录 remote 文件保持原 SHA-256（包括 Steam/控制器配置，不是对所有游戏存档的完整扫描）。
- 480 实际缓存票据、异步回调、65 秒 Windows 时长和成就解锁/回锁通过；独立 worker 确认 5 项原始状态已恢复。测试云、票据与广播配置均恢复为测试前状态。
- 48 项 Swift 核心测试通过，包括更新签名/篡改拒绝、ZIP 路径与代码签名、原子安装备份、库存配置、反馈遮盖和下载凭证路由。
- 公开 GitHub 资源的直连与 3 个镜像实测成功；结果只是测试时可用性，不是持续服务保证。

### 配置更新和发布

设置页可填写此移植版自己的 HTTPS `release.json`，开启启动检查，或先导入本地签名 JSON 再选择匹配 ZIP。更新只重启 Fluent Steam；旧应用保留在同目录 `Fluent Steam Mac.before-*.app`，可退出应用后通过 Finder 恢复。此构建尚无公共更新服务器，不会向原作者仓库发布。

`script/package_release.py --download-url https://YOUR-HOST/FluentSteamMac-0.2.9-arm64.zip` 生成应用/源码 ZIP、SHA-256 与 Ed25519 签名 `release.json`。空下载地址表示仅支持本地导入。更新公钥在 `Resources/UpdatePublicKey.txt`，私钥留在本机 `work/update-signing/private-key`，不进入源码或应用分发包；后续发布需保留同一私钥并增加 build。若要换钥匙，需要先通过旧钥匙签署包含新公钥的过渡版。

打包时 Windows PE/.NET 载荷位于 `Contents/Resources/Helpers`，作为资源封存；原生 Mach-O 单独签名。这样本地更新无需依赖容易在 ZIP 解压时丢失的扩展属性签名。分发包仍为本机临时签名，未公证。

### 自选离线游戏目录与成就定义

联机补丁页可选择自有游戏文件夹，使用文件夹名查询 Steam 商店 AppID，或手动输入 AppID；搜索只列出候选，不自动部署。Steamless 仍需对应 NotProton 前缀。Goldberg 可使用正在运行的 Steam 读取成就，或用仅保留在本次界面的 Web API Key 获取定义和可选图标；只导出定义，不复制在线解锁状态。图标限 HTTPS Steam 资源，写入受管目录并纳入备份恢复。接口依据 [Valve GetSchemaForGame 文档](https://partner.steamgames.com/doc/webapi/ISteamUserStats?l=english#GetSchemaForGame)。未提供 API Key，真实在线架构与库存查询仍未验收。

### Lua 访问令牌

导入和启用 Lua 时，`addtoken` 同步为 `FluentAccessTokens`，禁用时随 AppID 移除。已有 Lua 使用“同步已有 Lua 锁定与令牌”；需要运行环境中的 Fluent 原生运行时扩展。令牌约每秒热加载，只注入已启用 AppID 的 PICS 请求；UInt64 使用十进制文本保存，不经过浮点转换。原生隔离测试验证真实 Steam protobuf、发送钩子和调用者数据恢复，没有发送虚构令牌到网络。

### 0.2.1：按 AppID 选择 Steam Play 运行器

运行环境新增按 AppID 选择 Windows 兼容工具，适用于库中尚未显示的条目，以及宣称支持 macOS、实际入口却为 Windows EXE 的游戏。只修改所选 AppID 的 CompatToolMapping，保留其他游戏和全局设置；关闭 Steam 后保存，自动备份至权限 0700 的 CompatibilityBackups。选择“跟随 Steam 默认设置”可移除这项覆盖。配置不包含下载动作，不自动安装游戏。

0.2.1 本轮 50 项 Swift 核心测试通过。真实 Steam 运行中写入拒绝、配置不变检查通过；480 单项配置保存后解析对比确认其他配置不变。原生 Steam 已登录，原生与实际 NotProton Windows API 均能读取 Spacewar 成就；480 下载入口仍无反应。改用 The Expendabros（312990）后，真实 Steam 从 macOS depot 切换为 Windows depot，完成下载，通过 NotProton/CrossOver 启动 x86 EXE；用户确认游戏正常运行。当前覆盖本机这一游戏及版本组合，不等于所有游戏或全部功能已验收。窗口自动化读取超时，画面正常的结论来自用户确认。

### 0.2.2：修复好友广播默认未接管的问题

此前默认“跟随 Steam”且需要手填 AppID，不足以复刻原版默认开启的广播。0.2.2 当时默认每秒读取 macSteam `Apps` 主游戏列表和名称，通过 Spacewar 广播（该方式的通知身份仍为 Spacewar；0.2.5 曾移除，0.2.6 按用户选择恢复原版兼容策略）；DLC 条目和未启用游戏不自动加入，游戏禁用后自动退出范围。已有明确“隐藏”或“跟随 Steam”设置继续保留；不修改 Steam 账号隐私设置。无名称注释时优先保留消息中的名称，再回退到 AppID。

游戏消息计数已与云时长开关分离。新增有效范围、实际提交发送队列数、失败数、最近 AppID/时间；旧扩展有明确更新提示。“已提交”仅表示本地 Steam 发送接口接受，不代表好友已看到。51 项 Swift 测试和真实 ARM64 隔离发送回归通过；自动范围、标题改写、禁用热移除、其他游戏透传、显式隐藏与无效设置保护、关闭时长后观察、发送失败及调用者恢复均已验证。好友端实际显示另行记录在输出报告，不将钩子加载当作验收。

### 0.2.3：广播游戏名跟随应用语言

自动广播使用 Fluent Steam Mac 当前界面语言的同一份游戏资料；在设置页切换语言并保存后，同步更新广播标题，不固定为中文，也不使用 Steam 客户端语言覆盖应用选择。仅修改已启用主游戏的名称注释，写入前检查摘要并自动备份；DLC、密钥、开关及其他配置保留。中文与英文缓存分开读取，取消的旧请求不能覆盖新语言。关闭自动联网获取名称时仍可使用对应语言缓存；该语言资料缺失时保留游戏库当前回退名称，等待后续获取。

已加载的 0.2.2 扩展可热读取标题，无需重启 Steam。正在运行游戏的状态名在下一条真实游戏状态消息时更新，通常是下次启动/退出；不会伪造退出重进来刷新名称。好友客户端的显示、通知开关和送达延迟不由本应用控制，本机显示成功不能替代好友端通知验收。

0.2.3 验证：54 项核心测试通过；实际 UI 中文 → 英文 → 中文与两条主游戏广播名称来源同步通过，原偏好已恢复，Steam PID 不变。既有 9 个 remote 基线哈希不变（不是全部游戏存档清单）。

### 0.2.4：修复创意工坊下载缺少密钥

普通游戏 depot 列表不一定包含与主 AppID 相同的工坊仓库。此前生成器只写游戏 depot，漏掉本机缓存已有的 AppID 仓库密钥，导致游戏能安装但工坊报 Missing decryption key。现在生成清单会保留该密钥；游戏详情提供“补齐工坊密钥”，只为选定已启用主游戏补齐 Lua 与 macSteam 配置，先检查冲突并备份，不覆盖已有不同密钥。密钥来源仍是已有 Lua / 本机缓存；缺失时明确失败，不保证所有游戏或条目可下载。macSteam 需重启加载新密钥。

实机 Probably Stolen（4348910）：修复前14个订阅、0字节；修复后 Steam 自动完成下载，日志 No Error，14个目录、86个文件、8,891,099字节，NeedsDownload/NeedsUpdate 均为0。只增加一条配置密钥与一条 Lua 语句，其他字节保留，9个 remote 基线文件摘要不变。57项核心测试通过，包含归属/冲突/备份恢复和禁用再启用。未新增或取消订阅，未启动游戏验证 Mod 内部行为。


### 0.2.5：纠正好友广播的真实游戏身份

0.2.2–0.2.4 把游戏 GameID 替换为 480，再附上实际游戏名。这会使显示标题与游戏身份不一致；用户已反馈通知仍识别为 Spacewar。此前的本机标题和发送队列验证不足以证明好友广播正确。

0.2.5 当时将自动和手动选择模式改为保留原始 GameID，只更新标题；此策略已被 0.2.6 的兼容模式取代。移除 Spacewar 替代选项，旧 `spacewar` 设置读取为 `selected`；隐藏/跟随 Steam 的选择保持不变。多个游戏及实际 Spacewar 并行时不再合并条目，游戏丰富状态仅在明确隐藏时拦截。手动选中的已启用游戏标题也随应用语言更新，好友端最终名称和通知仍由 Steam 决定。

诊断新增 `presenceIdentity=real-appid` 和实际序列化发送消息的 `presenceLastGameID`，旧扩展会提示更新；发送队列接受仍不等于服务器或好友端确认。59项 Swift 测试和本机 Steam/macSteam 二进制隔离探针通过，含4348910真实ID、3321460/480/快捷方式并行、旧模式迁移、隐私与调用者消息恢复。探针不连接真实 Steam 会话，不将隔离成功写成好友通知验收。

实机0.2.5：正常退出并备份更新原生扩展，新Steam进程加载real-appid策略；用户通过NotProton启动深空当铺并确认停在主菜单。序列化消息的GameID=4348910，4次发送接口接受、0失败。该证据仍不代表好友端弹窗已验收。

后续反馈：用户报告0.2.5真实ID消息发送后仍无“正在游玩”显示，因此该功能仍未修复完成。当时设置切换为unchanged（跟随Steam）用于对照；用户随后选择参照原项目，现已启用0.2.6兼容模式。未发现明确服务端拒绝原因，不将账号授权问题写成已确认结论。0.2.5没有自动回退；0.2.6按用户确认恢复回退。

### 0.2.6：参照原版的兼容广播

按用户确认恢复兼容广播路线。自动/所选模式只处理最近启动的目标游戏，优先使用当前账号已注册的非Steam快捷方式GameID，并附上Fluent当前语言的实际游戏名；没有可用快捷方式时回退480。只改写目标条目的身份、标题与其owner字段，其他游戏的owner与内容不变。若可用身份已经被实际运行的其他游戏占用，不冒用其身份、不合并游戏条目。丰富状态上传保留Steam原始处理；隐藏所选仍是独立功能，跟随Steam则完全透传。

快捷方式解析读取当前账号shortcuts.vdf，完整解析有界二进制KV，不扫描任意字节模式，不跨账号借用快捷方式，拒绝符号链接、坏包、截断和重复ID；账号变更后旧快捷方式立即失效。没有快捷方式时不会替用户新增库条目。界面明确显示快捷方式数量、实际发送GameID及Spacewar回退会影响时长/通知的区别。

这是独立macOS发送适配，参照OpenSteamTool de818957的兼容广播行为；未复制Windows hook代码，也未加入其全局owner掩码或本机PersonaState伪造。原版自己界面的修饰不能证明好友端已收到，不把它当作通知成功依据。用户要求的应用语言优先于原版Steam客户端语言来源。

验证：59项Swift测试、实际ARM64 Steam/macSteam二进制隔离发送回归通过；覆盖快捷方式优先、Spacewar回退、栈顶顺序、完整UInt64身份、其他账号/游戏隔离、语言标题、发送失败及原调用者消息恢复。真实Steam已加载0.2.6，当前账号无快捷方式，自动模式将在游戏启动时回退480。用户选择暂不测试，本次没有新的真实游戏启动/发送证据；游戏状态与好友端通知仍待验收。

### 0.2.7：新入库游戏自动选择 NotProton

导入Lua/ZIP、搜索生成入库、重新启用及编辑已启用Lua后，按最终写入的主游戏仓库与平台资料自动检查。仅有Windows可用内容时选择已安装的NotProton：优先已有全局NotProton选择，否则选版本号较新的已安装运行器。包含macOS内容、DLC单独内容或资料不完整时保留设置；不会仅凭商店macOS标签判断。

Steam运行时只记录持久队列，不写config.vdf、不强制退出游戏。保持Fluent打开，Steam退出后自动备份应用；从Fluent启动/重启Steam前也会先处理。等待写入的游戏从Fluent启动时会提示先重启Steam，避免再次按错误平台启动。退出Fluent不会丢失队列，下次打开继续。离线、运行器未安装或资料不明时在运行环境页显示待处理原因，可重试。已下载的平台资料缓存24小时，未知判断约10分钟重试。

保留Steam中已有逐游戏选择；在Fluent手动保存的“跟随Steam默认设置”也会被记住，重新入库不覆盖。队列随入库事务一起备份与回滚，禁用/移除会取消待应用项；应用前再次检查游戏内容、用户设置与Steam进程。配置写入不涉及游戏存档、成就、下载开关或其他游戏。

67项核心测试通过，涵盖完整隔离入库/延后应用/还原与竞争条件。实际新版界面已验证，更新期间Steam PID不变；没有为验收此自动功能新加实机游戏。此前荒岛求生的单项手动修复已取得正确Windows下载清单，实际下载完成/游戏启动仍未验收。原生扩展保持0.2.6相同内容，无需重新部署。

### 0.2.8：归档、正版导出与官方运行器下载

游戏库导入现在支持 TAR、7z、RAR，选择器和拖放共用受限解压与原有导入预览/备份事务。只导入 Lua/Manifest/schema Bin；同名内容冲突拒绝，大小、条目、路径、链接和校验检查在写入前执行。真实 TAR、solid 7z、独立工具识别的 RAR4 样本贯穿完整隔离库导入与还原；RAR5、分卷及更多压缩算法尚未覆盖。

SteamKit 正版导出新增递归 DLC 子仓库、许可过滤、循环/重复仓库去重、共享仓库实际来源及部分失败报告。保留主游戏与 DLC 的 Lua 归属和 UInt64 令牌/Manifest。可选附带本机 `UserGameStatsSchema_<AppID>.bin`，不导出账号解锁状态；没有定义文件会明确提示。离线回归通过，真实已登录账号提取继续按用户要求暂缓扫码。

运行环境页新增官方版本检查、发布说明和下载校验。实际 macSteam 0.8.2 DMG 与 NotProton 1.2.4 ZIP 下载、SHA-256、严格代码签名、ARM64 与资源验证通过；NotProton 还通过现有安装器只读检查。下载包保存在私有缓存，不自动更改 Steam。匹配当前 Steam build 才自动选为安装来源，再由已有备份安装流程部署。实际 1.2.4 包只附带三个旧 build 的签名配置，没有当前 1792618285，故保留现有 1.2.3 来源；这不等同于已经证明 1.2.4 无法运行。

成就测试改用本机已安装游戏。《深空当铺》4348910 在用户进入主菜单并退出后仍返回 `EResult=2`，没有读到有效状态，未进行成就写入。界面明确区分读取失败与空列表，重新读取时清除旧游戏的可编辑状态。历史 Spacewar 测试不作为此游戏通过的证据。

本版还包含独立云存档会话完成的默认本地接管、自动主游戏范围、激活前备份及真实状态报告；该会话已按用户批准完成启用：实际3321460/4348910自动上传成功，9个原游戏存档与备份/独立存储摘要一致；仅Steam同步索引正常更新。完整游戏保存/读档与跨设备仍未验收。统一核心回归 79 项/15 suites 通过，不能据此宣称完整游戏云同步和全场景兼容已完成。

### 0.2.9：已安装游戏的兼容成就

修复添加游戏读取成就时的 `EResult=2`：按原项目取得公开 schema，仅启用所选游戏的当前账号统计，不导入来源账号的解锁记录。成就页面提供“初始化兼容成就”；重启 Steam 后读取。原生接口优先使用 UserStats013，兼容 012，并验证回调 AppID、用户句柄与 SteamID。

兼容模式保存后会重新请求当前用户状态，并独立核对账号/AppID 对应的本机统计文件。界面明确显示“兼容记录”，不会把 Valve 的失败回调改称服务器成功。未启用兼容模式的游戏仍需正常 Steam 成功回调。

实际使用已安装《深空当铺》4348910：读取 21 项成就；原生 macSteam 和 NotProton Windows x64 均完成 ACH_TUTORIAL 单项解锁、独立重读和还原；21 项布尔状态/时间戳恢复基线。没有使用 Spacewar 或扫码，其他游戏存档未操作。详情见 `outputs/成就修复与实测-0.2.9.md`。

本版同时集成用户侧聊授权的游戏库归属修复：保留 Steam 原生 owner，只对配置启用游戏清理错误共享标记，未知 owner 不再写成 1。严格限定当前 Steam/macSteam 版本；实际库页提示是否消失需界面确认，不等同于取得服务器许可证。
