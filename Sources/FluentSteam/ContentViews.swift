import SwiftUI
import AppKit
import FluentCore

struct DiscoverPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var dlc = true
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("发现下一款游戏", "Find your next game"), subtitle: model.tr("通过 Steam 名称或 AppID 查询，生成可预览的 Lua 清单。", "Search Steam by name or AppID and preview a generated Lua manifest.")) { EmptyView() }
            Panel {
                HStack(spacing: 13) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(Palette.accent)
                    TextField(model.tr("输入游戏名称或 AppID，例如 480", "Game title or AppID, e.g. 480"), text: $model.search).textFieldStyle(.plain).font(.system(size: 16)).onSubmit { model.searchGames() }
                    Button(model.tr("搜索", "Search")) { model.searchGames() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                }
                Divider().padding(.vertical, 10)
                HStack { Toggle(model.tr("同时查询 DLC", "Include DLC"), isOn: $dlc).toggleStyle(.checkbox); Spacer(); Text(model.tr("简体中文名称 · 支持原生 / Windows depot", "Localized names · native / Windows depots")).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if model.results.isEmpty {
                EmptyMessage(icon: "sparkle.magnifyingglass", title: model.tr("搜索，然后添加到你的游戏库", "Search, then add to your library"), detail: model.tr("生成依赖所选数据源。没有密钥的内容会明确标出；导入不会自动下载游戏。", "Generation depends on your content source. Missing depot keys are reported. Importing does not download the game."))
            } else {
                ForEach(model.results) { item in
                    Panel(padding: 15) {
                        HStack(spacing: 18) {
                            Cover(id: item.id, name: item.name, height: 95).frame(width: 205).clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.name).font(.system(size: 16, weight: .semibold))
                                HStack { Text("AppID \(String(item.id))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary); if item.mac { Pill(text: "macOS", color: Palette.green) }; if item.windows { Pill(text: "Windows · NotProton") } }
                                if model.games.contains(where: { $0.id == item.id && $0.enabled }) { Text(model.tr("已在 macSteam 游戏库", "Already enabled in macSteam")).font(.system(size: 11)).foregroundStyle(Palette.green) }
                            }
                            Spacer()
                            VStack(spacing: 9) {
                                Button(model.tr("生成清单", "Generate Lua")) { model.generate(item.id, dlc: dlc) }.buttonStyle(.borderedProminent).disabled(model.busy)
                                Button(model.tr("商店详情 ↗", "Store details ↗")) { model.openURL("https://store.steampowered.com/app/\(item.id)") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ImportPreview: View {
    @EnvironmentObject var model: AppModel
    var session: ImportSession
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "tray.and.arrow.down.fill").font(.title2).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) { Text(model.tr("导入预览", "Import preview")).font(.title2.bold()); Text("\(session.plan.documents.count) " + model.tr("个游戏", "games") + " · \(session.plan.files.count) " + model.tr("个文件", "files")).foregroundStyle(.secondary) }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(session.plan.documents, id: \.appID) { doc in
                        Panel(padding: 14) {
                            Text(doc.name.isEmpty ? "App \(doc.appID)" : doc.name).font(.headline)
                            Text("AppID \(String(doc.appID)) · \(doc.depots.count) depots · \(doc.dlcIDs.count) DLC").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !session.plan.replacing.isEmpty {
                        Label(model.tr("以下文件将备份后替换", "These files will be backed up and replaced"), systemImage: "clock.arrow.circlepath").font(.headline)
                        Text(session.plan.replacing.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                    }
                    if !session.plan.warnings.isEmpty {
                        Label(model.tr("兼容性与内容提示", "Compatibility and content notes"), systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber).font(.headline)
                        ForEach(Array(session.plan.warnings.enumerated()), id: \.offset) { _, warning in Text("• " + warning).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Label(model.tr("入库后自动检查内容平台：只有 Windows 内容时选择 NotProton；Steam 运行中会等待退出后应用，已有手动设置保留。", "After import, Windows-only content automatically selects NotProton. Changes wait for Steam to exit; existing manual settings are preserved."), systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                    InfoLine(title: "macSteam", value: model.paths.config.path)
                    InfoLine(title: "Lua", value: model.paths.lua.path)
                    Text(model.tr("原始 Lua 会保留。游戏、DLC 与 depot 密钥将转换到 macSteam 配置；修改前备份，可在“存档与备份”中还原。", "Original Lua files are retained. Games, DLC and depot keys are converted into macSteam configuration. Every changed file is backed up for restoration.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button(model.tr("取消", "Cancel")) { model.pendingImport = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.tr("导入并启用", "Import and enable")) { model.commitImport() }.buttonStyle(.borderedProminent).disabled(model.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 680, height: 560)
    }
}

struct GameDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let game: Game
    @ViewState<String> private var tab = "overview"
    @ViewState<String> private var lua = ""
    @ViewState<String> private var original = ""
    @ViewState<AppInfo?> private var info: AppInfo?
    @ViewState<Bool> private var removal = false
    @ViewState<String> private var workshopStatus = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 17) {
                Cover(id: game.id, name: game.name, height: 76).frame(width: 162).clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 8) { Text(game.name).font(.system(size: 22, weight: .bold)); Text("AppID \(String(game.id)) · \(game.source)").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }.padding(24)
            Picker("", selection: $tab) { Text(model.tr("概览", "Overview")).tag("overview"); Text("DLC / Depots").tag("dlc"); Text("Lua").tag("lua") }.pickerStyle(.segmented).padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == "overview" { overview }
                    else if tab == "dlc" { depotView }
                    else { luaView }
                }.padding(24)
            }
            Divider()
            HStack {
                if game.source != "Steam" { Button(model.tr("移除清单…", "Remove entry…"), role: .destructive) { removal = true } }
                Spacer(); Button(model.tr("导出", "Export")) { model.export([game]) }
                if game.source != "Steam" { Button(game.enabled ? model.tr("禁用", "Disable") : model.tr("启用", "Enable")) { model.toggle(game); dismiss() }.disabled(model.busy) }
                Button(model.tr("启动游戏", "Launch game")) { model.launchGame(game) }.buttonStyle(.borderedProminent)
            }.padding(20)
        }.frame(width: 780, height: 650)
            .task {
                do { let (config, _) = try model.service.configSnapshot(); lua = try game.luaURL.map { try FileStore.text($0) } ?? config.lua(for: game.id); original = lua }
                catch { model.fail(error) }
            }
            .confirmationDialog(model.tr("移除 Lua 与 macSteam 入库记录？游戏安装文件会保留。", "Remove Lua and macSteam entries? Installed game files are retained."), isPresented: $removal) {
                Button(model.tr("备份后移除", "Back up and remove"), role: .destructive) { model.remove(game); dismiss() }
            }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel {
                InfoLine(title: model.tr("入库状态", "Library state"), value: game.enabled ? model.tr("macSteam 已启用", "Enabled in macSteam") : model.tr("未启用", "Not enabled"))
                InfoLine(title: model.tr("安装状态", "Installation"), value: game.installed == nil ? model.tr("未检测到本地安装", "No local installation found") : model.tr("已安装", "Installed"))
                InfoLine(title: "BuildID", value: game.installed?.buildID ?? "—")
                InfoLine(title: "Lua", value: game.luaURL?.path ?? model.tr("来自 macSteam 配置", "From macSteam configuration"))
                if let installed = game.installed { InfoLine(title: model.tr("游戏目录", "Game folder"), value: installed.folder.path) }
            }
            HStack {
                Button(model.tr("Steam 详情", "Steam details")) { model.openURL("steam://nav/games/details/\(game.id)") }
                Button(model.tr("商店页面", "Store page")) { model.openURL("https://store.steampowered.com/app/\(game.id)") }
                Button(model.tr("管理成就", "Manage achievements")) { model.achievementApp = String(game.id); model.page = .achievements; dismiss() }
                SaveManagerShortcut(appID: game.id)
                if let folder = game.installed?.folder { Button(model.tr("游戏文件", "Game files")) { model.openFolder(folder) } }
                if let prefix = SteamLibrary.prefixes(model.paths).first(where: { $0.id == game.id })?.url {
                    Menu("NotProton") {
                        Button(model.tr("打开前缀", "Open prefix")) { model.openFolder(prefix) }
                        Button("winecfg") { model.wineTool(game, command: "winecfg") }
                        Button("regedit") { model.wineTool(game, command: "regedit") }
                        Button(model.tr("任务管理器", "Task manager")) { model.wineTool(game, command: "taskmgr") }
                        Button(model.tr("Wine 日志", "Wine log")) { model.reveal(model.paths.notProton.appendingPathComponent("launchers/\(game.id)/notproton-wine.log")) }
                    }
                }
            }
            if game.enabled {
                Panel {
                    HStack {
                        Text(model.tr("创意工坊下载", "Workshop downloads")).font(.subheadline.bold())
                        Spacer()
                        Button(model.tr("补齐工坊密钥", "Repair Workshop key")) {
                            model.run(model.tr("补齐工坊仓库密钥", "Repair Workshop depot key")) {
                                do {
                                let record = try WorkshopKeys.repair(appID: game.id, paths: model.paths)
                                if record != nil { model.needsRestart = true }
                                model.refresh()
                                workshopStatus = record == nil ? model.tr("密钥已存在，无需更改。若刚补齐过，请先重启 Steam；仍失败时查看工坊日志。", "Key already present. Restart Steam if it was recently repaired; check Workshop logs if downloads still fail.") : model.tr("已备份并补齐 Lua 与 macSteam 配置。退出游戏并重启 Steam 后，在下载页重试；下载结果以 Steam 为准。", "Lua and macSteam configuration backed up and repaired. Exit games, restart Steam, then retry in Downloads; Steam reports the download result.")
                                if let url = game.luaURL { lua = try FileStore.text(url); original = lua }
                                } catch { workshopStatus = error.localizedDescription; throw error }
                            }
                        }.disabled(model.busy || lua != original)
                    }
                    Text(model.tr("用于已订阅但报“缺少解密密钥”的下载。只使用该游戏已有 Lua 或本机缓存中的密钥；不会取消订阅或清空 Mod。", "For subscribed downloads reporting a missing decryption key. Uses this game's Lua or local key cache; preserves subscriptions and existing mods.")).font(.caption).foregroundStyle(.secondary)
                    if !workshopStatus.isEmpty { Text(workshopStatus).font(.caption).textSelection(.enabled) }
                }
            }
            if !game.warnings.isEmpty { Panel { ForEach(Array(game.warnings.enumerated()), id: \.offset) { _, warning in Label(warning, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Palette.amber).padding(.vertical, 3) } } }
        }
    }
    private var depotView: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(model.tr("DLC 与仓库数据", "DLC and depot data")).font(.headline); Spacer()
                Button(model.tr("查询最新数据", "Query latest")) {
                    model.run(model.tr("查询 DLC 与 Depot", "Query DLC and depots")) { info = try await model.api.appInfo(game.id) }
                }.disabled(model.busy)
                Button(model.tr("补全 DLC…", "Complete DLC…")) { dismiss(); model.generate(game.id, dlc: true, existing: game) }.disabled(model.busy)
            }
            if let info {
                ForEach(info.depots) { depot in
                    Panel(padding: 12) {
                        HStack { Text("Depot \(String(depot.id))").font(.system(size: 12, weight: .semibold, design: .monospaced)); Pill(text: depot.os); Spacer(); Text(depot.manifest.isEmpty ? "—" : depot.manifest).font(.system(size: 10, design: .monospaced)) }
                    }
                }
                Text("DLC · \(info.dlc.count)").font(.headline)
                ForEach(info.dlc, id: \.self) { id in HStack { Text("AppID \(String(id))"); Spacer(); Pill(text: game.dlcIDs.contains(id) ? model.tr("已在清单", "In manifest") : model.tr("未入库", "Missing"), color: game.dlcIDs.contains(id) ? Palette.green : Palette.amber) }.font(.system(size: 12)) }
            } else { Text(model.tr("点击查询以对照当前 Lua 与 Steam 公开数据。", "Query to compare this Lua file with Steam's published data.")).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
    private var luaView: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $lua).font(.system(size: 11, design: .monospaced)).frame(minHeight: 270).border(.secondary.opacity(0.15))
            HStack {
                Menu(model.tr("版本信息写入 Lua", "Write version pins to Lua")) {
                    Button(model.tr("使用当前安装版本", "Use installed versions")) {
                        do { guard let depots = game.installed?.depots, !depots.isEmpty else { throw AppFailure("未找到已安装的 depot 清单 / No installed depot manifests found") }; lua = try LuaDocument.parse(lua, suggestedID: game.id).pinning(depots).raw } catch { model.fail(error) }
                    }
                    Button(model.tr("使用最新公开版本", "Use latest public versions")) {
                        model.run(model.tr("查询版本", "Query versions")) { let info = try await model.api.appInfo(game.id); lua = try LuaDocument.parse(lua, suggestedID: game.id).pinning(Dictionary(uniqueKeysWithValues: info.depots.filter { !$0.manifest.isEmpty }.map { ($0.id, $0.manifest) })).raw }
                    }
                    Button(model.tr("移除版本锁定语句", "Remove version pins")) { do { lua = try LuaDocument.parse(lua, suggestedID: game.id).pinning(nil).raw } catch { model.fail(error) } }
                }
                Spacer()
                Button(model.tr("保存并同步", "Save and sync")) {
                    model.run(model.tr("保存 Lua", "Save Lua")) { try model.service.saveLua(lua, game: game); original = lua; model.needsRestart = true; model.refresh() }
                }.buttonStyle(.borderedProminent).disabled(lua == original || model.busy)
            }
            Text(model.tr("版本锁定需在运行环境安装 Fluent Manifest 扩展，并在清单管理缓存对应 Manifest。支持 ARM64 Steam build 1792618285 的 public 分支；保存后约 1 秒刷新，正在进行的下载需停止后重试。", "Version pins require the Fluent Manifest extension and the matching cached manifest. Supports the public branch on ARM64 Steam build 1792618285. Refreshes within about one second; stop and retry an active download.")).font(.system(size: 11)).foregroundStyle(Palette.amber)
        }
    }
}

struct ManifestPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var depot = ""
    @ViewState<String> private var manifest = ""
    var files: [URL] { FileStore.files(model.paths.depotCache).filter { $0.pathExtension == "manifest" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("清单管理", "Manifest manager"), subtitle: model.tr("导入 depot 清单，或按指定版本获取并校验下载数据。", "Import depot manifests or download and verify a specific version.")) {
                Button(model.tr("打开 depotcache", "Open depotcache")) { model.openFolder(model.paths.depotCache) }
            }
            Panel {
                HStack {
                    Label(model.tr("自动监听与修复", "Monitor and repair"), systemImage: "waveform.path").font(.headline)
                    Spacer()
                    if model.monitorRunning { Button(model.tr("停止监听", "Stop monitoring")) { model.stopManifestMonitor() } }
                    else { Button(model.tr("开始监听", "Start monitoring")) { model.startManifestMonitor() }.buttonStyle(.borderedProminent) }
                }
                Text(model.tr("只处理 macSteam 已启用游戏的新 Manifest 请求。启动监听后在 Steam 重试下载；完成后再次重试。关闭窗口可继续监听，退出应用即停止。", "Handles new manifest requests for enabled macSteam games. Retry the Steam download after starting and after repairs finish. Monitoring continues when the window closes and stops when the app quits.")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(model.monitorStatus); Spacer(); Text(model.tr("成功", "Completed") + " \(model.monitorCompleted) · " + model.tr("失败", "Failed") + " \(model.monitorFailed)") }.font(.system(size: 11)).padding(.top, 6)
            }
            Panel {
                Text(model.tr("获取缺失的 Manifest", "Fetch a missing manifest")).font(.headline)
                HStack {
                    TextField("DepotID", text: $depot).textFieldStyle(.roundedBorder)
                    TextField("ManifestID", text: $manifest).textFieldStyle(.roundedBorder)
                    Button(model.tr("获取", "Fetch")) { if let id = TextUtil.validID(depot) { model.repairManifest(depot: id, manifest: manifest) } }.buttonStyle(.borderedProminent).disabled(model.busy || TextUtil.validID(depot) == nil || UInt64(manifest) == nil)
                }
                Text(model.tr("下载源可在设置中修改；只在格式与 CRC 校验通过后写入。", "Configure the source in Settings. Files are written only after format and CRC validation.")).font(.caption).foregroundStyle(.secondary)
            }
            Panel {
                HStack { Text(model.tr("本地清单", "Local manifests")).font(.headline); Spacer(); Text("\(files.count)").foregroundStyle(.secondary); Button(model.tr("导入文件", "Import files")) { model.chooseImport() } }
                if files.isEmpty { EmptyMessage(icon: "doc.badge.arrow.up", title: model.tr("还没有缓存清单", "No cached manifests"), detail: model.tr("Steam 下载过的 depot manifest 会显示在这里。", "Depot manifests cached by Steam appear here.")) }
                ForEach(files, id: \.path) { file in
                    HStack { Image(systemName: "doc.text").foregroundStyle(Palette.accent); Text(file.lastPathComponent).font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Spacer(); Button(model.tr("显示", "Reveal")) { model.reveal(file) } }.padding(.vertical, 6)
                }
            }
        }
    }
}
