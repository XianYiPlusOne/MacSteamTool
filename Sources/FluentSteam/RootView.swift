import SwiftUI
import UniformTypeIdentifiers
import FluentCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 222)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "desktopcomputer").foregroundStyle(Palette.accent)
                    Text("macOS").fontWeight(.medium)
                    Text("/").foregroundStyle(.tertiary)
                    Text(model.title(model.page)).foregroundStyle(.secondary)
                    Spacer()
                    if model.testing { Pill(text: "隔离测试环境", color: .orange) }
                    Circle().fill(model.steamRunning ? Palette.green : .secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(model.steamRunning ? model.tr("Steam 运行中", "Steam running") : model.tr("Steam 未运行", "Steam stopped")).foregroundStyle(.secondary)
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help(model.tr("刷新", "Refresh"))
                }.font(.system(size: 11)).padding(.horizontal, 30).padding(.vertical, 18)
                if !model.runtimeUpdateProviders.isEmpty {
                    HStack {
                        Label(model.tr("运行内核有更新：", "Runtime updates: ") + model.runtimeUpdateProviders.joined(separator: ", "), systemImage: "arrow.down.circle")
                        Spacer(); Button(model.tr("查看更新", "View updates")) { model.page = .runtime }
                    }.font(.caption).padding(12).background(Palette.accent.opacity(0.08)).padding(.horizontal, 30)
                }
                if model.needsRestart {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(model.tr("入库配置已更新，重启 Steam 后检查游戏库。", "Library configuration updated. Restart Steam to apply."))
                        Spacer(); Button(model.tr("重启 Steam", "Restart Steam")) { model.restartSteam() }.disabled(model.busy)
                    }.font(.system(size: 12)).padding(12).background(Palette.accent.opacity(0.08)).padding(.horizontal, 30)
                }
                ScrollView {
                    Group {
                        switch model.page {
                        case .library: LibraryPage()
                        case .discover: DiscoverPage()
                        case .manifests: ManifestPage()
                        case .trainers: TrainersPage()
                        case .patches: PatchesPage()
                        case .achievements: AchievementsPage()
                        case .saves: SavesPage()
                        case .accounts: AccountsPage()
                        case .runtime: RuntimePage()
                        case .compatibility: CompatibilityPage()
                        case .settings: SettingsPage()
                        }
                    }.padding(30).frame(maxWidth: 1450, alignment: .topLeading).frame(maxWidth: .infinity)
                }.id(model.page)
                bottomBar
            }.background { if model.preferences.materialBackground == true { Rectangle().fill(.regularMaterial) } else { (scheme == .dark ? Color(white: 0.085) : Color(red: 0.962, green: 0.968, blue: 0.983)) } }
        }
        .tint(Palette.accent)
        .task { await model.bootstrap() }
        .sheet(item: $model.pendingImport) { session in ImportPreview(session: session).environmentObject(model) }
        .sheet(item: $model.selectedGame) { game in GameDetailView(game: game).environmentObject(model) }
        .alert(item: $model.message) { message in Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text(model.tr("知道了", "OK")))) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let data: Data? = await withCheckedContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in continuation.resume(returning: data) }
                    }
                    if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                if !urls.isEmpty { model.prepareImport(urls) }
            }
            return true
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(LinearGradient(colors: [Palette.accent, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fluent Steam").font(.system(size: 15, weight: .bold))
                    Text("MAC EDITION").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(.top, 27).padding(.bottom, 34).padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.tr("游戏与内容", "GAMES & CONTENT")).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.horizontal, 25).padding(.bottom, 10)
                    ForEach([Page.library, .discover, .manifests, .trainers, .patches, .achievements, .saves]) { row($0) }
                    Text(model.tr("管理", "MANAGEMENT")).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.horizontal, 25).padding(.top, 30).padding(.bottom, 10)
                    ForEach([Page.accounts, .runtime, .compatibility, .settings]) { row($0) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "link").foregroundStyle(Palette.accent)
                    Text("macSteam + NotProton").font(.system(size: 10, weight: .semibold))
                }
                HStack(spacing: 6) {
                    Circle().fill(model.runtime.bothInjected ? Palette.green : Palette.amber).frame(width: 5, height: 5)
                    Text(model.runtime.bothInjected ? model.tr("已检测到双内核", "Both libraries detected") : model.tr("查看环境状态", "Review runtime status")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button { model.launchSteam() } label: {
                    Label(model.tr("启动 Steam", "Launch Steam"), systemImage: "play.fill").font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.bordered).controlSize(.large)
            }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13)).padding(15)
            Text((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.1") + " · " + model.tr("移植开发版", "Development port")).font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 23).padding(.bottom, 20)
        }.background(.regularMaterial)
    }
    private func row(_ page: Page) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 12) {
                Image(systemName: page.icon).font(.system(size: 14)).frame(width: 20)
                Text(model.title(page)).font(.system(size: 12, weight: model.page == page ? .semibold : .regular))
                Spacer()
                if page == .library { Text("\(model.games.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
            }.foregroundStyle(model.page == page ? Palette.accent : Color.primary.opacity(0.72)).padding(.horizontal, 13).padding(.vertical, 11)
                .background(model.page == page ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 2)
    }
    private var bottomBar: some View {
        HStack(spacing: 9) {
            if model.busy { ProgressView().controlSize(.mini); Text(model.progress).lineLimit(1); Spacer(); if model.canCancelOperation { Button(model.tr("取消", "Cancel")) { model.cancel() }.buttonStyle(.plain) } }
            else {
                Image(systemName: "checkmark.circle").foregroundStyle(Palette.green)
                Text(model.eventLog.first ?? model.tr("已读取本地 Steam 游戏库", "Local Steam library loaded")).lineLimit(1)
                Spacer(); Text(model.lastRefresh.formatted(date: .omitted, time: .shortened)).foregroundStyle(.tertiary)
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 30).padding(.vertical, 12).background(.background)
    }
}

struct LibraryPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<Bool> private var selecting = false
    @ViewState<Set<Int>> private var selected = []
    @ViewState<Bool> private var confirmRemoval = false
    var chosen: [Game] { model.games.filter { selected.contains($0.id) && $0.source != "Steam" } }
    private func selection(_ game: Game) -> some View {
        Toggle("App \(game.id)", isOn: Binding(get: { selected.contains(game.id) }, set: { if $0 { selected.insert(game.id) } else { selected.remove(game.id) } })).toggleStyle(.checkbox).disabled(game.source == "Steam" || model.busy)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: model.tr("你的游戏，一处管理。", "Your games. One library."), subtitle: model.tr("管理 Lua 清单，连接原生 Steam 与 Windows 游戏。", "Manage Lua manifests for native Steam and Windows games.")) {
                Button { model.chooseImport() } label: { Label(model.tr("导入清单", "Import manifests"), systemImage: "plus").padding(.horizontal, 6).padding(.vertical, 5) }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
            HStack(spacing: 15) {
                metric(model.tr("全部游戏", "ALL GAMES"), count: model.games.count, icon: "square.stack.3d.up", color: Palette.accent)
                metric(model.tr("已启用", "ENABLED"), count: model.games.filter(\.enabled).count, icon: "checkmark.seal", color: Palette.green)
                metric(model.tr("本地已安装", "INSTALLED"), count: model.games.filter { $0.installed != nil }.count, icon: "internaldrive", color: .orange)
            }
            HStack {
                Picker("", selection: $model.filter) {
                    Text(model.tr("全部", "All")).tag("all"); Text(model.tr("已启用", "Enabled")).tag("enabled")
                    Text(model.tr("已禁用", "Disabled")).tag("disabled"); Text(model.tr("已安装", "Installed")).tag("installed")
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField(model.tr("搜索名称或 AppID", "Name or AppID"), text: $model.query).textFieldStyle(.plain) }.padding(9).background(.background, in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 235)
                Picker("", selection: $model.preferences.layout) {
                    Image(systemName: "square.grid.2x2").tag("cards"); Image(systemName: "rectangle.grid.1x2").tag("compact"); Image(systemName: "list.bullet").tag("list")
                }.pickerStyle(.segmented).frame(width: 106).onChange(of: model.preferences.layout) { _, _ in model.savePreferences() }
            }
            HStack {
                Toggle(model.tr("选择模式", "Selection mode"), isOn: $selecting).toggleStyle(.checkbox)
                if selecting {
                    Button(model.tr("全选筛选结果", "Select filtered")) { selected.formUnion(model.visibleGames.filter { $0.source != "Steam" }.map(\.id)) }
                    Button(model.tr("清除选择", "Clear selection")) { selected = [] }
                    Text("\(chosen.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.tr("启用所选", "Enable selected")) { model.batchLibrary(chosen, action: .enable) }.disabled(chosen.isEmpty)
                    Button(model.tr("禁用所选", "Disable selected")) { model.batchLibrary(chosen, action: .disable) }.disabled(chosen.isEmpty)
                    Button(model.tr("删除所选…", "Delete selected…"), role: .destructive) { confirmRemoval = true }.disabled(chosen.isEmpty)
                }
            }.disabled(model.busy)
            .confirmationDialog(model.tr("备份后删除所选清单？游戏安装文件保留。", "Back up and delete selected entries? Installed games are retained."), isPresented: $confirmRemoval) {
                Button(model.tr("删除 \(chosen.count) 个清单", "Delete \(chosen.count) entries"), role: .destructive) { model.batchLibrary(chosen, action: .remove); selected = [] }
            }
            if model.visibleGames.isEmpty {
                Panel {
                    EmptyMessage(icon: "tray.and.arrow.down", title: model.tr("从一份 Lua 清单开始", "Start with a Lua manifest"), detail: model.tr("拖入 Lua 或 ZIP 文件，也可以通过游戏名、AppID 搜索。已有 macSteam 入库记录会自动显示。", "Drop a Lua or ZIP file, or search by game name and AppID. Existing macSteam entries appear automatically."))
                    HStack { Spacer(); Button(model.tr("搜索游戏", "Find games")) { model.page = .discover }; Button(model.tr("导入本地文件", "Import local files")) { model.chooseImport() }.buttonStyle(.borderedProminent); Spacer() }.padding(.bottom, 25)
                }
            } else if model.preferences.layout == "list" {
                Panel(padding: 8) { VStack(spacing: 0) { ForEach(model.visibleGames) { game in HStack { if selecting { selection(game) }; GameRow(game: game) }; if game.id != model.visibleGames.last?.id { Divider().padding(.leading, 85) } } } }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.preferences.layout == "compact" ? 185 : 245), spacing: 18)], spacing: 18) {
                    ForEach(model.visibleGames) { game in VStack(alignment: .leading) { if selecting { selection(game) }; GameCard(game: game) } }
                }
            }
            HStack {
                Label(model.tr("更改前自动备份", "Automatic backups before changes"), systemImage: "clock.arrow.circlepath")
                Spacer(); Button(model.tr("导出当前列表", "Export current list")) { model.export(model.visibleGames) }.buttonStyle(.plain).disabled(model.visibleGames.isEmpty || model.busy)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func metric(_ title: String, count: Int, icon: String, color: Color) -> some View {
        Panel(padding: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary); Text("\(count)").font(.system(size: 28, weight: .semibold, design: .rounded)) }
                Spacer(); Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(color).padding(12).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }
}
struct GameCard: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Cover(id: game.id, name: game.name, height: model.preferences.layout == "compact" ? 100 : 126)
                .overlay(alignment: .topTrailing) { Pill(text: game.source, color: .white).background(.black.opacity(0.45), in: Capsule()).padding(10) }
                .contentShape(Rectangle()).onTapGesture { model.selectedGame = game }
            VStack(alignment: .leading, spacing: 11) {
                Text(game.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).onTapGesture { model.selectedGame = game }
                HStack { Text("APP \(String(game.id))").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary); Spacer(); Text("\(game.depotCount) depots").font(.system(size: 9)).foregroundStyle(.tertiary) }
                Divider()
                HStack {
                    Pill(text: game.enabled ? model.tr("已启用", "Enabled") : game.source == "Steam" ? "Steam" : model.tr("已禁用", "Disabled"), color: game.enabled ? Palette.green : .secondary)
                    if game.installed != nil { Image(systemName: "internaldrive").foregroundStyle(.secondary).help(model.tr("已安装", "Installed")) }
                    if !game.warnings.isEmpty { Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.amber).help(game.warnings.joined(separator: "\n")) }
                    Spacer()
                    SaveManagerShortcut(appID: game.id, compact: true).buttonStyle(.plain)
                    Menu {
                        Button(model.tr("查看详情", "Details")) { model.selectedGame = game }
                        SaveManagerShortcut(appID: game.id)
                        Button(model.tr("在 Steam 中打开", "Open in Steam")) { model.openURL("steam://nav/games/details/\(game.id)") }
                        if game.source != "Steam" { Button(game.enabled ? model.tr("禁用", "Disable") : model.tr("启用", "Enable")) { model.toggle(game) } }
                        Button(model.tr("导出", "Export")) { model.export([game]) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                }.font(.system(size: 11))
            }.padding(15)
        }.background(.background, in: RoundedRectangle(cornerRadius: 14)).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.07), lineWidth: 1))
            .contentShape(Rectangle())
    }
}
struct GameRow: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    var body: some View {
        HStack(spacing: 14) {
            Cover(id: game.id, name: game.name, height: 42).frame(width: 84).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) { Text(game.name).font(.system(size: 13, weight: .medium)); Text("AppID \(String(game.id)) · \(game.depotCount) depots · \(game.dlcIDs.count) DLC").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer(); Pill(text: game.enabled ? model.tr("已启用", "Enabled") : game.source)
            SaveManagerShortcut(appID: game.id)
            Button(model.tr("详情", "Details")) { model.selectedGame = game }
        }.padding(10)
    }
}
