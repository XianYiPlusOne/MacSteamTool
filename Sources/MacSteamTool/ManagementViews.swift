import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacSteamToolCore

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
            RuntimeFeaturesPanel()
        }
    }
}

struct RuntimePage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("运行环境", "Runtime environment"), subtitle: model.tr("选择 Wine 或自己购买的 CrossOver。原生 Steam 接入由程序自动维护。", "Choose Wine or your purchased CrossOver. Native Steam integration is maintained automatically.")) { Button(model.tr("重新检测", "Check again")) { model.refresh() } }
            RuntimeSetupPanel(flow: model.runtimePreparation)
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
                        InfoLine(title: model.tr("MacSteamTool 运行架构", "Running MacSteamTool architecture"), value: AppUpdates.architecture)
                        InfoLine(title: model.tr("Steam 支持的架构", "Steam executable architectures"), value: model.runtime.steamArchitectures.isEmpty ? model.tr("未读取到", "Unknown") : model.runtime.steamArchitectures.map(\.rawValue).joined(separator: " / "))
                        if let running = model.runtime.runningSteamArchitecture {
                            InfoLine(title: model.tr("Steam 正在使用的架构", "Running Steam architecture"), value: running.rawValue)
                        }
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
    var standalone = false
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var migrateLua = true
    var body: some View {
        VStack(spacing: 0) {
            if standalone {
                header.padding(.leading, windowControlsInset).padding(.trailing, 24).padding(.top, 10)
                    .background(WindowHeaderBackground())
            }
            settingsList
        }
    }

    private var header: some View {
        PageHeader(title: model.tr("按你的方式使用", "Make it yours"), subtitle: model.tr("外观、目录与网络数据源。修改后保存生效。", "Appearance, locations and content sources. Save to apply changes.")) {
            Button(model.tr("保存设置", "Save settings")) { model.savePreferences(migrateLua: migrateLua) }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }
    }

    private var settingsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !standalone { header }
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
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                    Text(model.tr("版本 \(version)", "Version \(version)")).font(.headline)
                }
            }.padding(standalone ? 24 : 0)
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
