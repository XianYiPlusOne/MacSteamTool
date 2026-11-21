import SwiftUI
import AppKit
import FluentCore

struct ImportPreview: View {
    @EnvironmentObject var model: AppModel
    var session: ImportSession
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "tray.and.arrow.down.fill").font(.title2).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) { Text(model.tr("导入预览", "Import preview")).font(.title2.bold()); Text("\(session.plan.documents.count) " + model.tr("个游戏", "games") + " · \(session.plan.files.count) " + model.tr("个文件", "files")).foregroundStyle(.secondary) }
                Spacer()
                if session.automatic && !AuthorizedContentRepair.missingDepots(in: session.plan.warnings).isEmpty {
                    Button(model.tr("账号授权补齐", "Repair with owned account")) { model.repairAuthorizedContent() }.disabled(model.busy)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.automatic {
                        Label(!session.verificationDepots.isEmpty ? model.tr("内容已齐，可使用 Steam 账号核验后继续导入。", "Content found. Verify with Steam to continue.") : session.complete ? model.tr("待确认导入，尚未入库", "Awaiting confirmation; not yet imported") : model.tr("内容缺失或待核实，请补齐并重新检查后入库", "Content missing or unverified; complete the check before importing"), systemImage: "info.circle").foregroundStyle(Palette.amber)
                        ForEach(session.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
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
                    if !session.plan.warnings.isEmpty || !session.content.isEmpty {
                        Label(model.tr("兼容性与内容提示", "Compatibility and content notes"), systemImage: "exclamationmark.triangle").foregroundStyle(Palette.amber).font(.headline)
                        ImportContentList(items: session.content)
                        ForEach(Array(session.plan.warnings.enumerated()), id: \.offset) { _, warning in Text("• " + warning).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    ImportCheckLog(lines: session.checkLog)
                    Label(model.tr("入库后自动检查内容平台，Windows 游戏使用所选兼容层。需要重启 Steam 时会提示，已有单独设置保留。", "After import, Windows games use your selected translation backend. You will be prompted if Steam needs to restart; individual choices are preserved."), systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                    Text(model.tr("原始 Lua 会保留，游戏配置由本程序自动管理。修改前备份，可在“存档与备份”中还原。", "Original Lua files are retained and game configuration is managed automatically. Changed files are backed up for restoration.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button(model.tr("取消", "Cancel")) { model.cancelImport() }.disabled(model.busy).keyboardShortcut(.cancelAction)
                Spacer()
                if session.automatic && !session.unavailableDLC.isEmpty {
                    Button(model.tr("跳过不可用的可选 DLC 并重查", "Exclude unverified optional DLC and recheck")) { model.excludeUnverifiedDLC() }.disabled(model.busy)
                }
                if !session.verificationDepots.isEmpty {
                    Button(model.tr("使用 Steam 账号核验", "Verify with Steam")) { model.repairAuthorizedContent() }
                        .buttonStyle(.borderedProminent).disabled(model.busy).keyboardShortcut(.defaultAction)
                } else {
                    Button(model.tr("导入并启用", "Import and enable")) { model.commitImport() }.buttonStyle(.borderedProminent).disabled(model.busy || (session.automatic && !session.complete)).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 820, height: 720)
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
                if game.source != "Steam" { Button(model.tr("移除游戏…", "Remove game…"), role: .destructive) { model.requestGameRemoval([game]); dismiss() } }
                Spacer(); Button(model.tr("导出", "Export")) { model.export([game]) }
                if game.source != "Steam" { Button(game.enabled ? model.tr("禁用", "Disable") : model.tr("启用", "Enable")) { model.toggle(game); dismiss() }.disabled(model.busy) }
                Button(model.tr("启动游戏", "Launch game")) { model.launchGame(game) }.buttonStyle(.borderedProminent)
            }.padding(20)
        }.frame(width: 780, height: 650)
            .task {
                do { let (config, _) = try model.service.configSnapshot(); lua = try game.luaURL.map { try FileStore.text($0) } ?? config.lua(for: game.id); original = lua }
                catch { model.fail(error) }
            }

    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let installed = game.installed { GameStartupPanel(game: installed) }
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
                Button(model.tr("管理容器", "Manage containers")) { model.containerAppID = game.id; model.page = .containers; dismiss() }
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
            ManifestHubPanel()
            ForEach(["code", "hub"], id: \.self) { source in
                Panel {
                    let running = source == "hub" ? model.hubMonitorRunning : model.monitorRunning
                    HStack {
                        Label(source == "hub" ? "ManifestHub" : "Code / CDN", systemImage: "waveform.path").font(.headline)
                        Spacer()
                        if running { Button(model.tr("停止监听", "Stop monitoring")) { model.stopManifestMonitor(source: source) } }
                        else { Button(model.tr("开始监听", "Start monitoring")) { model.startManifestMonitor(source: source) }.buttonStyle(.borderedProminent) }
                    }
                    Text(source == "hub" ? model.hubMonitorStatus : model.monitorStatus).font(.caption)
                    Text(model.tr("成功", "Completed") + " \(source == "hub" ? model.hubMonitorCompleted : model.monitorCompleted) · " + model.tr("失败", "Failed") + " \(source == "hub" ? model.hubMonitorFailed : model.monitorFailed)").font(.caption)
                    Text(model.tr("仅处理已启用游戏的新请求。两个来源保留各自状态，启动一个会停止另一个；关闭窗口继续监听，退出应用后停止。", "Handles new requests for enabled games. Each source keeps its own status; starting one stops the other; monitoring continues with the window closed and stops when the app quits.")).font(.caption).foregroundStyle(.secondary)
                }
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
