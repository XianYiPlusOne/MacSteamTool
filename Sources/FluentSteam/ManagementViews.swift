import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FluentCore

struct AccountsPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("Steam 本地账号", "Local Steam accounts"), subtitle: model.tr("使用 Steam 已保存的登录记录；切换前请先退出 Steam。", "Use login records saved by Steam. Quit Steam before switching.")) { Button(model.tr("打开 Steam", "Open Steam")) { model.launchSteam() } }
            if model.accounts.isEmpty { Panel { EmptyMessage(icon: "person.crop.circle.badge.questionmark", title: model.tr("没有可用的本地账号", "No saved local accounts"), detail: model.tr("先在 Steam 登录并选择记住登录。这里不会收集密码。", "Sign into Steam and enable remembered login. This app does not collect passwords.")) } }
            ForEach(model.accounts) { account in
                Panel {
                    HStack(spacing: 17) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(Palette.accent.opacity(0.7))
                        VStack(alignment: .leading, spacing: 5) { Text(account.persona).font(.system(size: 16, weight: .semibold)); Text(account.name).font(.system(size: 12)).foregroundStyle(.secondary) }
                        if account.recent { Pill(text: model.tr("最近登录", "Most recent"), color: Palette.green) }
                        Spacer(); Button(model.tr("切换并启动", "Switch & launch")) { model.switchAccount(account) }.disabled(model.busy || model.steamRunning)
                    }
                }
            }
            OnlineAccountPanel()
            RuntimeFeaturesPanel()
        }
    }
}

struct RuntimePage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("运行环境", "Runtime environment"), subtitle: model.tr("选择 Wine 或自己购买的 CrossOver。原生 Steam 接入由程序自动维护。", "Choose Wine or your purchased CrossOver. Native Steam integration is maintained automatically.")) { Button(model.tr("重新检测", "Check again")) { model.refresh() } }
            TranslationRuntimePanel(flow: model.runtimePreparation)
            Panel {
                Label(model.tr("独立游戏容器", "Per-game containers"), systemImage: "shippingbox").font(.headline)
                Text(model.tr("为单个游戏创建容器、运行 Windows 工具，或备份和恢复整个容器。", "Create a container for a game, run Windows tools, or back up and restore a whole container.")).font(.caption).foregroundStyle(.secondary)
                Button(model.tr("管理游戏容器", "Manage game containers")) { model.containerAppID = nil; model.page = .containers }
            }
            DisclosureGroup(model.tr("诊断与恢复（高级）", "Diagnostics and recovery (advanced)")) {
                VStack(alignment: .leading, spacing: 22) {
                    Panel {
                        HStack(spacing: 15) {
                            Image(systemName: model.runtime.bothInjected ? "checkmark.shield" : "exclamationmark.shield").font(.system(size: 32)).foregroundStyle(model.runtime.bothInjected ? Palette.green : Palette.amber)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(model.runtime.bothInjected ? model.tr("原生 Steam 接入已配置", "Native Steam integration is configured") : model.tr("原生 Steam 接入待准备", "Native Steam integration needs preparation")).font(.system(size: 18, weight: .semibold))
                                Text(model.tr("内置接入组件随本程序更新，由程序自动初始化和维护。这里显示配置和加载诊断。", "Built-in integration components update with this app and are initialized and maintained automatically. Configuration and loading diagnostics appear here.")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Panel {
                        Label(model.tr("接入诊断", "Integration diagnostics"), systemImage: "stethoscope").font(.headline)
                        InfoLine(title: model.tr("配置文件", "Configuration"), value: model.runtime.configExists ? model.tr("已找到", "Found") : model.tr("未找到", "Missing"))
                        InfoLine(title: model.tr("当前 Steam 适配数据", "Current Steam compatibility data"), value: model.runtime.macSteamSignature && model.runtime.notProtonSignature ? model.tr("已找到", "Found") : model.tr("未确认", "Unconfirmed"))
                        InfoLine(title: model.tr("内容接入加载结果", "Content integration loading"), value: model.runtime.macSteamLoaded.isEmpty ? model.tr("尚无当前进程的成功记录", "No success record for this process") : model.runtime.macSteamLoaded)
                        InfoLine(title: model.tr("游戏启动接入加载结果", "Game launch integration loading"), value: model.runtime.notProtonLoaded.isEmpty ? model.tr("尚无当前进程的成功记录", "No success record for this process") : model.runtime.notProtonLoaded)
                        Divider().padding(.vertical, 8)
                        InfoLine(title: "Wine", value: FreeRuntime.installedRoot(model.paths) == nil ? model.tr("未安装", "Not installed") : (FreeRuntime.graphicsReady(model.paths) ? model.tr("已就绪", "Ready") : model.tr("图形组件待更新", "Graphics update available")))
                        InfoLine(title: "CrossOver", value: "\(model.runtime.runners.count) " + model.tr("个运行器", "runners"))
                        InfoLine(title: model.tr("游戏独立环境", "Per-game environments"), value: String(model.runtime.prefixCount))
                    }
                    RuntimeActions()
                    Panel {
                        Text("Steam").font(.headline)
                        InfoLine(title: model.tr("应用路径", "Application"), value: model.paths.steamApp.path)
                        InfoLine(title: model.tr("数据目录", "Data directory"), value: model.paths.steam.path)
                        InfoLine(title: model.tr("客户端构建", "Client build"), value: model.runtime.build.isEmpty ? model.tr("未读取到", "Unknown") : model.runtime.build)
                        InfoLine(title: model.tr("游戏库目录", "Library folders"), value: SteamLibrary.libraries(model.paths).map(\.path).joined(separator: "\n"))
                        Divider().padding(.vertical, 8)
                        InfoLine(title: model.tr("接入文件", "Integration files"), value: model.runtime.bothInjected ? model.tr("完整", "Complete") : model.tr("等待自动准备", "Awaiting automatic preparation"))
                        HStack { Button(model.tr("启动 Steam", "Launch Steam")) { model.launchSteam() }; Button(model.tr("重启 Steam", "Restart Steam")) { model.restartSteam() }.disabled(model.busy); Spacer(); Button(model.tr("Steam 日志", "Steam logs")) { model.openFolder(model.paths.steam.appendingPathComponent("logs")) } }.padding(.top, 12)
                    }
                    Panel {
                        Text(model.tr("操作日志", "Activity log")).font(.headline)
                        if !model.runtime.runtimeWarnings.isEmpty { Text(model.runtime.runtimeWarnings.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.amber).textSelection(.enabled) }
                        if model.eventLog.isEmpty { Text(model.tr("尚无操作记录", "No recorded operations")).foregroundStyle(.secondary).font(.caption) }
                        Text(model.eventLog.prefix(25).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    SteamCompatibilityPanel()
                }.padding(.top, 12)
            }
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var migrateLua = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: model.tr("按你的方式使用", "Make it yours"), subtitle: model.tr("外观、目录与网络数据源。修改后保存生效。", "Appearance, locations and content sources. Save to apply changes.")) { Button(model.tr("保存设置", "Save settings")) { model.savePreferences(migrateLua: migrateLua) }.buttonStyle(.borderedProminent).disabled(model.busy) }
                Panel {
                    Text(model.tr("外观与行为", "Appearance & behavior")).font(.headline)
                    Picker(model.tr("语言", "Language"), selection: $model.preferences.language) { Text("简体中文").tag("zh"); Text("English").tag("en") }.frame(maxWidth: 330)
                    Picker(model.tr("主题", "Theme"), selection: $model.preferences.theme) { Text(model.tr("跟随系统", "System")).tag("system"); Text(model.tr("浅色", "Light")).tag("light"); Text(model.tr("深色", "Dark")).tag("dark") }.pickerStyle(.segmented).frame(maxWidth: 420)
                    Toggle(model.tr("半透明背景材质", "Translucent background"), isOn: Binding(get: { model.preferences.materialBackground == true }, set: { model.preferences.materialBackground = $0 }))
                    Toggle(model.tr("监控文件变更并自动刷新", "Refresh when files change"), isOn: $model.preferences.autoRefresh)
                    Toggle(model.tr("自动获取游戏名称", "Fetch game names automatically"), isOn: $model.preferences.autoMetadata)
                }
                Panel {
                    Text(model.tr("本地目录", "Local folders")).font(.headline)
                    pathField("Steam.app", value: $model.preferences.steamAppPath, placeholder: model.defaults.steamApp.path, app: true)
                    pathField(model.tr("Steam 数据", "Steam data"), value: $model.preferences.steamPath, placeholder: model.defaults.steam.path)
                    pathField("Lua", value: $model.preferences.luaPath, placeholder: model.defaults.lua.path)
                    Toggle(model.tr("更改或重置 Lua 目录时迁移原清单（含已禁用）", "Migrate Lua files, including disabled games, when changing or resetting the folder"), isOn: $migrateLua)
                    Text(model.tr("留空使用默认目录。迁移前请退出 Steam；复制校验成功才切换，原目录保留。同名不同内容不会覆盖。", "Leave blank for the default folder. Quit Steam before migration. Switch only after copy verification; originals are retained and conflicts are not overwritten.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Panel {
                    Text(model.tr("内容数据源", "Content sources")).font(.headline)
                    Text("Depot keys · HTTPS").font(.caption).foregroundStyle(.secondary)
                    TextField("https://…/depotkeys.json", text: $model.preferences.depotKeysURL).textFieldStyle(.roundedBorder)
                    Text("Manifest request code · {depot} / {manifest}").font(.caption).foregroundStyle(.secondary)
                    TextField("https://…/{depot}/{manifest}", text: $model.preferences.manifestURL).textFieldStyle(.roundedBorder)
                    Toggle(model.tr("源失效时尝试其他内置 HTTPS 源与 Steam CDN", "Try other built-in HTTPS sources and Steam CDNs on failure"), isOn: Binding(get: { model.preferences.manifestFallbacks != false }, set: { model.preferences.manifestFallbacks = $0 }))
                    HStack {
                        Button(model.tr("更新密钥缓存", "Update depot key cache")) {
                            model.run(model.tr("更新 depot 密钥", "Update depot keys")) { let count = try await model.content.refreshKeys(preferences: model.preferences); model.log("\(count) depot keys") }
                        }.disabled(model.busy)
                        Button(model.tr("打开缓存", "Open cache")) { model.openFolder(model.paths.cache) }
                    }.padding(.top, 8)
                    LibraryFallbackSettings()
                }
                DownloadPreferencesPanel()
                CachePanel()
                UpdatePanel()
                FeedbackPanel()
                Panel {
                    Text("Fluent Steam Mac · " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")).font(.headline)
                    Text(model.tr("基于 Fluent-Steam-Lua 的功能设计重新实现的 macOS 移植开发版。详细实现范围见“功能对照”。", "A macOS development port based on Fluent-Steam-Lua's feature design. See Feature parity for implementation details.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack { Button(model.tr("原项目 ↗", "Original project ↗")) { model.openURL("https://github.com/huanyuejue/Fluent-Steam-Lua") }; Button("macSteam ↗") { model.openURL("https://github.com/crghofficial/macsteam") }; Button("NotProton ↗") { model.openURL("https://github.com/NotProtonNot/NotProton") } }
                }
            }.padding(model.page == .settings ? 0 : 24)
        }
    }
    private func pathField(_ label: String, value: Binding<String>, placeholder: String, app: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).frame(width: 95, alignment: .leading)
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder).font(.system(size: 10))
            Button { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = app; if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path } } label: { Image(systemName: "folder") }
        }.padding(.vertical, 3)
    }
}

struct FeatureRow: Identifiable {
    let name: String; let english: String; let level: Int; let note: String; let englishNote: String
    var id: String { name }
}
struct CompatibilityPage: View {
    @EnvironmentObject var model: AppModel
    let features: [FeatureRow] = [
        .init(name: "游戏库 / 三种布局 / 搜索 / 封面", english: "Library, layouts, search, covers", level: 2, note: "读取 macSteam、Lua 和本地 Steam 库", englishNote: "Reads macSteam, Lua and local Steam libraries"),
        .init(name: "多格式导入 / Lua、Manifest、Bin 导出", english: "Archive import / Lua, Manifest and Bin export", level: 2, note: "ZIP / TAR / 7z / RAR：受限解压、预览、备份与还原", englishNote: "ZIP/TAR/7z/RAR: bounded extraction, preview, backup and rollback"),
        .init(name: "名称 / AppID 搜索与生成入库", english: "Search and generate Lua", level: 2, note: "Steam 商店 + depot 数据源，入库前预览", englishNote: "Steam Store and depot sources, with import preview"),
        .init(name: "DLC 查询、补全、清单启用 / 禁用", english: "DLC lookup, completion, enable/disable", level: 2, note: "写入 macSteam 的 Apps / DepotKeys", englishNote: "Updates macSteam Apps and DepotKeys"),
        .init(name: "Lua addtoken 访问令牌", english: "Lua addtoken access tokens", level: 1, note: "随 AppID 启用与禁用、热加载；真实 Steam PICS 请求与 UInt64 精度隔离测试通过，在线消费待验证", englishNote: "Follows AppID enable/disable with hot reload; real Steam PICS and UInt64 isolation tests passed; online consumption unverified"),
        .init(name: "独立游戏容器 / Windows 工具 / 备份恢复", english: "Game containers, Windows tools, backup and restore", level: 2, note: "按游戏创建 Wine / CrossOver 容器，支持设置、注册表、EXE / MSI、备份恢复与重置", englishNote: "Per-game Wine/CrossOver containers with settings, registry, EXE/MSI, backups, restoration and reset"),
        .init(name: "Steam 启动 / 重启 / 本地账号切换", english: "Steam launch, restart, account switch", level: 2, note: "复用已保存登录记录，切换前需退出 Steam", englishNote: "Uses remembered logins; Steam must be closed for switching"),
        .init(name: "版本锁定 / Manifest 下载", english: "Version pins / manifest downloads", level: 1, note: "Fluent Manifest 扩展已通过真实 ARM64 Steam 函数隔离测试；支持 build 1792618285 public 分支和有效缓存，真实下载待回归", englishNote: "Fluent Manifest passed isolated tests against real ARM64 Steam functions; build 1792618285 public branch and validated caches supported, live downloads unverified"),
        .init(name: "内核安装 / 更新 / 卸载", english: "Kernel install, update and uninstall", level: 2, note: "官方版本查询、下载与校验已实测；匹配 Steam build 后选为来源，沿用备份安装与恢复", englishNote: "Official release checks, downloads and validation passed; matching Steam builds select a source for backed-up installation and restore"),
        .init(name: "本地存档备份 / 还原 / 清空", english: "Local save backup, restore and reset", level: 2, note: "校验后还原，替换和清空前保存当前副本", englishNote: "Verified restoration; current files are backed up before replacement or clearing"),
        .init(name: "云存档 API 重定向 / 自动迁移", english: "Cloud API redirection and migration", level: 1, note: "本地 WebDAV/S3/R2 双客户端上传、恢复与错误路径已通过；真实外部服务和游戏内恢复待验证", englishNote: "Loopback WebDAV/S3/R2 independent-client upload, restore and failure paths passed; external services and in-game restoration remain unverified"),
        .init(name: "正版账号在线提取 Lua / 密钥", english: "Online owned-game and key extraction", level: 1, note: "DLC 递归、共享仓库、权限与部分失败、可选本地成就 Bin 已接入；扫码实测暂缓", englishNote: "DLC recursion, shared depots, licensing, partial failures and optional local schema Bin implemented; authenticated testing deferred"),
        .init(name: "成就管理 / 正常游玩解锁", english: "Achievement management and gameplay unlocks", level: 1, note: "新入库自动准备；深空当铺正常游玩解锁、通知及独立回读通过。本次正常初始化已验收，不代表 Valve 公开资料同步", englishNote: "Automatic preparation for new games; Probably Stolen gameplay unlock, notification and independent read passed. Current successful initialization accepted; no claim of Valve public-profile sync"),
        .init(name: "游戏启动检查", english: "Game startup diagnostics", level: 2, note: "按选定游戏读取最近 Unity 日志，区分初始化失败、成功和无法判断；不修改游戏或存档", englishNote: "Reads only the selected game's latest Unity log and distinguishes failed, successful and unknown initialization without modifying game data"),
        .init(name: "创意工坊", english: "Steam Workshop", level: 2, note: "深空当铺订阅下载问题已修复，用户确认正常；实际游戏识别到 14 个工坊项目", englishNote: "Probably Stolen subscription downloads repaired and confirmed working by the user; the game detected 14 Workshop items"),
        .init(name: "Denuvo appticket / eticket", english: "Denuvo appticket / eticket", level: 1, note: "双票据导入、账号绑定消费与异步回调已实现；480 原生实机消费通过，Denuvo 游戏待验证", englishNote: "Import, account-bound consumption and async callbacks implemented; live native 480 consumption passed; Denuvo games unverified"),
        .init(name: "ConnectTool 联机", english: "ConnectTool multiplayer", level: 1, note: "页面内集成房间、邀请、聊天/置顶、TCP 和 TUN；本机房间流程通过，双设备待验收", englishNote: "Embedded rooms, invitations, chat/pinning, TCP and TUN; local room flow passed; two-device acceptance pending"),
        .init(name: "SteamStub 去除 / Goldberg 部署", english: "SteamStub removal / Goldberg deployment", level: 1, note: "官方 Steamless 插件与合成 PE 解包通过；Goldberg 本地 480 API / 成就往返通过，实际游戏待测", englishNote: "Official Steamless plugins and synthetic PE unpack passed; Goldberg local 480 API/achievement round trip passed; actual games pending"),
        .init(name: "自选游戏目录 / 离线成就定义", english: "Custom game folders / offline achievement definitions", level: 1, note: "文件夹名称查询 AppID、手动输入、Web API 成就定义和可选图标；商店查询实测通过，在线定义待提供 API Key", englishNote: "Folder-name AppID search, manual entry, Web API definitions and optional icons; live Store search passed; online definitions await an API key"),
        .init(name: "Manifest 自动监听修复 / CDN 切换", english: "Manifest monitoring and CDN fallback", level: 2, note: "监听新增日志请求，验证内容后写入 depotcache", englishNote: "Tails new log requests and validates downloaded manifests before caching"),
        .init(name: "好友游玩状态广播", english: "Friend game presence", level: 2, note: "广播名称跟随应用语言；好友通知已通过用户实测验收", englishNote: "Presence titles follow the app language; friend notifications accepted through user testing"),
        .init(name: "云统计 / 游戏时长", english: "Cloud statistics and playtime", level: 1, note: "WebDAV/S3/R2 同时写入版本校验、冲突重试、断线重开补传及独立客户端合并通过本地服务测试；外部账号与实体设备待验收", englishNote: "WebDAV/S3/R2 conditional writes, conflict retries, offline restart recovery and independent-client merges passed loopback tests; external accounts and physical devices remain unverified"),
        .init(name: "内核 Manifest Provider 热切换", english: "Kernel manifest provider switching", level: 1, note: "macSteam / Steam / 自定义 HTTPS，按 AppID 热加载；实际 macSteam 函数隔离回归通过", englishNote: "Per-app hot switching between macSteam, Steam and custom HTTPS; isolated tests against the actual macSteam handler passed"),
        .init(name: "签名自动更新 / 本地更新", english: "Signed online and local updates", level: 2, note: "可配置 HTTPS 更新源、启动检查、签名与摘要校验、原子替换及上一版备份；暂无公共发布地址", englishNote: "Configurable HTTPS feed, launch checks, signature/digest validation, atomic replacement and previous-version backup; no public feed yet"),
        .init(name: "反馈报告 / 下载偏好 / 离线库存", english: "Feedback, download preferences and offline inventory", level: 2, note: "本地报告预览与导出、GitHub 镜像测速、Steam CDN 偏好、Goldberg 库存定义导入", englishNote: "Local report preview/export, GitHub mirror benchmarking, Steam CDN preferences and Goldberg inventory definitions"),
        .init(name: "菜单栏常驻 / 窗口恢复", english: "Menu bar and window restoration", level: 2, note: "关闭主窗口后可继续监听，从菜单栏恢复", englishNote: "Monitoring continues after closing the main window; restore it from the menu bar"),
        .init(name: "浅色 / 深色 / 语言 / 文件监控", english: "Themes, language, file monitoring", level: 2, note: "双语主界面、背景材质开关、核心错误和导入警告的双语说明", englishNote: "Bilingual UI, optional background material, and bilingual core errors and import warnings")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("功能对照与移植进度", "Feature parity and port status"), subtitle: model.tr("对照原项目 1.5.4.2 · 已补齐主要编码缺口，以下注明各项验证范围。", "Compared with upstream 1.5.4.2. Major implementation gaps filled; validation scope is listed below.")) { EmptyView() }
            Panel {
                Text(model.tr("macSteam 是 macOS 内核；OpenSteamTool 是 Windows 内核。二者接口并不相同，Windows DLL 功能不能仅靠更换界面实现。", "macSteam and OpenSteamTool expose different runtime interfaces. Windows DLL features require additional native porting.")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(features) { feature in
                Panel(padding: 16) {
                    HStack {
                        Image(systemName: feature.level == 2 ? "checkmark.circle.fill" : feature.level == 1 ? "circle.lefthalf.filled" : "circle.dashed").foregroundStyle(feature.level == 2 ? Palette.green : feature.level == 1 ? Palette.amber : .secondary)
                        VStack(alignment: .leading, spacing: 5) { Text(model.tr(feature.name, feature.english)).font(.system(size: 13, weight: .semibold)); Text(model.tr(feature.note, feature.englishNote)).font(.system(size: 11)).foregroundStyle(.secondary) }
                        Spacer(); Pill(text: feature.level == 2 ? model.tr("已实现", "Implemented") : feature.level == 1 ? model.tr("部分实现", "Partial") : model.tr("待移植", "Not ported"), color: feature.level == 2 ? Palette.green : feature.level == 1 ? Palette.amber : .secondary)
                    }
                }
            }
        }
    }
}
