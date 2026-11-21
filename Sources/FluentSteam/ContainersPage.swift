import SwiftUI
import AppKit
import FluentCore

struct ContainersPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<[GameContainer]> private var containers = []
    @ViewState<[ContainerBackend]> private var backends = []
    @ViewState<[InstalledGame]> private var installed = []
    @ViewState<String> private var gameKey = ""
    @ViewState<String> private var backendID = ""
    @ViewState<String> private var profileName = ""
    @ViewState<[ContainerProfile]> private var profiles = []
    @ViewState<UUID?> private var selection = nil
    @ViewState<Bool> private var creating = false
    @ViewState<ContainerProfile?> private var trashing = nil
    private struct SwitchAction {
        let title: String
        let apply: @MainActor () async throws -> Void
    }
    @ViewState<SwitchAction?> private var switchAction = nil
    @ViewState<String> private var notice = ""
    @ViewState<String> private var search = ""
    @ViewState<GameContainer?> private var pending = nil
    @ViewState<Bool> private var resetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("容器管理", "Game containers"), subtitle: model.tr("为游戏选择启动环境，管理各容器的组件、注册表和存档。", "Choose a launch environment and manage its components, registry and saves.")) {
                Button(model.tr("刷新", "Refresh"), action: reload).disabled(model.busy)
            }
            Panel {
                if installed.isEmpty {
                    Text(model.tr("安装一款 Steam 游戏后，即可为它创建容器。", "Install a Steam game to create its containers."))
                } else {
                    Picker(model.tr("游戏", "Game"), selection: $gameKey) {
                        ForEach(installed, id: \.folder.path) { item in
                            Text(verbatim: "\(item.name) · \(item.id)" + (installed.filter { $0.id == item.id }.count > 1 ? " · " + item.library.path : "")).tag(item.folder.path)
                        }
                    }.disabled(model.busy)
                    HStack {
                        Text(model.tr("此游戏的容器", "Containers for this game")).font(.headline)
                        Spacer()
                        Button {
                            profileName = ""; creating = true
                        } label: { Label(model.tr("新建独立容器", "New container"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                    }
                    ForEach(profiles) { profile in
                        let selected = selection == profile.id
                        Button {
                            selection = profile.id
                            notice = ""
                        } label: {
                            HStack {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? Palette.accent : .secondary)
                                Text(title(profile)).fontWeight(selected ? .semibold : .regular)
                                Spacer()
                                Text(toolName(profile)).foregroundStyle(.secondary)
                                if profile.active { Pill(text: model.tr("当前启动容器", "Active at launch"), color: Palette.green) }
                            }
                            .padding(9).background(selected ? Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                    if let selected = profiles.first(where: { $0.id == selection }), !selected.active {
                        HStack {
                            Button(model.tr("切换到此容器", "Switch to this container")) {
                                activate(selected)
                            }.buttonStyle(.borderedProminent).disabled(model.busy)
                            Button(model.tr("在访达中显示", "Show in Finder")) { model.openFolder(selected.directory) }
                            if selected.name != nil {
                                Spacer()
                                Button(model.tr("移至废纸篓…", "Move to Trash…"), role: .destructive) { trashing = selected }.disabled(model.busy)
                            }
                        }
                    }
                    if let store, store.needsRecovery {
                        Button(model.tr("恢复中断的切换", "Recover interrupted switch")) {
                            requestSwitch(model.tr("恢复容器选择", "Recover container selection")) { try await store.recover() }
                        }
                    }
                    if !notice.isEmpty { Text(notice).font(.callout).foregroundStyle(.secondary) }
                }
            }
            if let selected = profiles.first(where: { $0.id == selection }), selected.active {
                let entries = containers.filter { $0.appID == game?.id && $0.library.standardizedFileURL == game?.library.standardizedFileURL }
                ForEach(entries) { container in containerRow(container) }
                if entries.isEmpty {
                    Text(model.tr("首次启动 Windows 游戏时，Steam 会初始化当前环境。也可以点“新建独立容器”提前准备。", "Steam initializes this environment on first Windows launch. Use New container to prepare a separate one now.")).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !unlisted.isEmpty {
                DisclosureGroup(model.tr("其他游戏库容器", "Other library containers")) {
                    TextField(model.tr("搜索名称或 AppID", "Search name or AppID"), text: $search).textFieldStyle(.roundedBorder)
                    ForEach(unlisted.filter { search.isEmpty || name($0).localizedCaseInsensitiveContains(search) || String($0.appID).contains(search) }) { containerRow($0) }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: gameKey) { _, _ in selection = nil; notice = ""; loadProfiles() }
        .onChange(of: model.busy) { _, busy in if !busy { reload() } }
        .sheet(isPresented: $creating) { createSheet }
        .confirmationDialog(model.tr("退出 Steam 并应用更改？", "Quit Steam and apply the change?"), isPresented: Binding(get: { switchAction != nil }, set: { if !$0 { switchAction = nil } }), titleVisibility: .visible, presenting: switchAction) { action in
            Button(model.tr("退出 Steam 并继续", "Quit Steam and continue")) { apply(action, quitSteam: true) }
            Button(model.tr("取消", "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(model.tr("请先保存并关闭游戏。更改将在 Steam 退出后应用，然后重新打开 Steam。", "Save and close your game first. Fluent will apply the change after Steam exits, then reopen Steam."))
        }
        .confirmationDialog(model.tr("将选中的容器移至废纸篓？", "Move the selected container to Trash?"), isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }), titleVisibility: .visible, presenting: trashing) { item in
            Button(model.tr("移至废纸篓", "Move to Trash"), role: .destructive) {
                guard let store, let id = item.id else { return }
                perform(model.tr("移除容器", "Remove container")) { try await store.moveToTrash(id); notice = "" }
            }
            Button(model.tr("取消", "Cancel"), role: .cancel) {}
        } message: { item in
            Text(model.tr("“\(title(item))”的 Windows 环境和容器内存档将一起移至废纸篓。", "The Windows environment and in-container saves for “\(title(item))” will move to Trash together."))
        }
        .confirmationDialog(resetting ? model.tr("备份后重置容器？当前容器中的组件、设置和存档会先完整备份，然后创建空白容器；游戏文件保留。", "Reset after backup? Components, settings and saves in this container are backed up in full, then a blank container is created. Game files are retained.") : model.tr("备份后移除容器？可在此页从备份恢复，游戏安装文件和另一兼容层的容器保留。", "Remove after backup? Restore it here from its backup. Game installation files and the other backend's container are retained."), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let container = pending {
                Button(resetting ? model.tr("备份并重置", "Back up & reset") : model.tr("备份并移除", "Back up & remove"), role: .destructive) {
                    let reset = resetting; pending = nil
                    perform(model.tr("更新容器", "Update container")) {
                        let backend = try GameContainers.backend(for: container, paths: model.paths)
                        if reset && backend == nil { throw AppFailure(model.tr("请先准备此容器使用的兼容层版本。", "Prepare this container's backend version first.")) }
                        _ = try await GameContainers.remove(container, paths: model.paths)
                        if reset, let backend { try await GameContainers.create(container, backend: backend, paths: model.paths) }
                    }
                }
            }
        }
    }
    private func containerRow(_ container: GameContainer) -> some View {
        let backend = try? GameContainers.backend(for: container, paths: model.paths)
        let selected = try? GameContainers.selectedTool(appID: container.appID, paths: model.paths)
        let copies = GameContainers.backups(container, paths: model.paths)
        return Panel {
            HStack {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(container)).font(.headline)
                    Text("AppID \(container.appID) · " + (backend?.name ?? (container.isWine ? "Wine" : "CrossOver"))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let backend, selected == backend.id { Pill(text: model.tr("此游戏当前选择", "Selected for this game"), color: Palette.green) }
            }
            Text(container.exists ? (container.ready ? model.tr("容器已创建", "Container created") : model.tr("容器不完整，可备份后重置", "Incomplete container; back up and reset")) : model.tr("容器已移除，可从下方备份恢复", "Container removed; restore from a backup below")).font(.caption).foregroundStyle(.secondary)
            Text(container.prefix.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if container.exists {
                HStack {
                    Button(model.tr("打开容器", "Open container")) { model.openFolder(container.prefix) }
                    Menu(model.tr("容器工具", "Container tools")) {
                        Button(model.tr("Windows 设置", "Windows settings")) { runTool("winecfg", container) }
                        Button(model.tr("注册表编辑器", "Registry editor")) { runTool("regedit", container) }
                        Button(model.tr("任务管理器", "Task manager")) { runTool("taskmgr", container) }
                        Button(model.tr("运行 EXE / MSI…", "Run EXE / MSI…")) { chooseExecutable(container) }
                    }.disabled(model.busy || model.steamRunning || !container.ready || backend == nil)
                    Button(model.tr("查看日志", "View log")) { model.reveal(GameContainers.logURL(container, paths: model.paths)) }
                    Spacer()
                    if let backend, selected != backend.id, container.ready {
                        Button(model.tr("使用此运行器", "Use this runner")) {
                            requestSwitch(model.tr("选择游戏运行器", "Select game runner")) {
                                let fixture = model.testing
                                _ = try SteamCompatibility.save(paths: model.paths, appID: container.appID, tool: backend.id, requireIdle: { if !fixture { try GameContainers.requireIdle() } })
                            }
                        }.disabled(model.busy)
                    }
                }
                HStack {
                    Button(model.tr("备份容器", "Back up container")) { perform(model.tr("备份容器", "Back up container")) { _ = try await GameContainers.backup(container, paths: model.paths) } }
                    Button(model.tr("重置容器…", "Reset container…")) { resetting = true; pending = container }.disabled(backend == nil)
                    Button(model.tr("移除容器…", "Remove container…")) { resetting = false; pending = container }
                }.disabled(model.busy || model.steamRunning)
            }
            if !copies.isEmpty {
                DisclosureGroup(model.tr("容器备份", "Container backups") + " (\(copies.count))") {
                    Text(model.tr("恢复前会备份当前容器。备份包含容器内存档，不包含游戏安装目录或容器外存档。", "The current container is backed up before restoration. Backups include in-container saves, but exclude installed game files and saves outside the container.")).font(.caption).foregroundStyle(.secondary)
                    ForEach(copies) { copy in
                        HStack {
                            Text(copy.created.formatted()).font(.caption)
                            Spacer()
                            Button(model.tr("恢复此备份", "Restore backup")) { perform(model.tr("恢复容器", "Restore container")) { try await GameContainers.restore(copy, to: container, paths: model.paths) } }.disabled(model.busy || model.steamRunning)
                        }
                    }
                }
            }
        }
    }
    private func name(_ container: GameContainer) -> String { model.games.first(where: { $0.id == container.appID })?.name ?? "App \(container.appID)" }
    private var game: InstalledGame? { installed.first { $0.folder.path == gameKey } }
    private var unlisted: [GameContainer] {
        containers.filter { entry in !installed.contains { $0.id == entry.appID && $0.library.standardizedFileURL == entry.library.standardizedFileURL } }
    }
    private func title(_ profile: ContainerProfile) -> String { profile.name ?? model.tr("默认容器", "Default container") }
    private func toolName(_ profile: ContainerProfile) -> String {
        backends.first { $0.id == profile.tool }?.name ?? profile.tool ?? model.tr("Steam 默认", "Steam default")
    }
    private var store: ContainerProfiles? {
        game.map { ContainerProfiles(appID: $0.id, library: $0.library, paths: model.paths) }
    }
    private func reload() {
        do {
            installed = SteamLibrary.installed(model.paths).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            backends = try GameContainers.backends(model.paths)
            containers = GameContainers.all(model.paths) + GameContainers.recoverable(model.paths)
            if game == nil {
                gameKey = installed.first(where: { $0.id == model.containerAppID })?.folder.path ?? installed.first?.folder.path ?? ""
            }
            loadProfiles()
        } catch { model.fail(error) }
    }
    private func loadProfiles() {
        do {
            profiles = try store?.list() ?? []
            if !profiles.contains(where: { $0.id == selection }) { selection = profiles.first?.id }
            backendID = profiles.first?.tool.flatMap { tool in backends.first { $0.id == tool }?.id } ?? backends.first?.id ?? ""
        } catch { profiles = []; model.fail(error) }
    }
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.tr("新建独立容器", "New container")).font(.title2.bold())
            Text(game?.name ?? "").foregroundStyle(.secondary)
            if backends.isEmpty {
                Text(model.tr("先准备 Wine 或 CrossOver，再创建容器。", "Set up Wine or CrossOver to create a container."))
                Button(model.tr("前往运行环境", "Open Runtime")) { creating = false; model.page = .runtime }
            } else {
                TextField(model.tr("容器名称", "Container name"), text: $profileName).textFieldStyle(.roundedBorder)
                Picker(model.tr("运行器", "Runner"), selection: $backendID) {
                    ForEach(backends) { Text($0.name).tag($0.id) }
                }
                Text(model.tr("新容器从空白 Windows 环境开始。创建后可在列表中切换。", "Start with a fresh Windows environment. Switch to it from the list when ready.")).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(model.tr("取消", "Cancel")) { creating = false }.keyboardShortcut(.cancelAction)
                if !backends.isEmpty {
                    Button(model.tr("创建容器", "Create container"), action: create).keyboardShortcut(.defaultAction)
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backendID.isEmpty || model.busy)
                }
            }
        }.padding(24).frame(width: 430)
    }
    private func create() {
        guard let store, let backend = backends.first(where: { $0.id == backendID }) else { return }
        let name = profileName
        creating = false
        perform(model.tr("创建独立容器", "Create container")) {
            selection = try await store.create(name: name, backend: backend)
            notice = model.tr("已创建“\(name)”，可切换用于下次启动。", "Created “\(name)”. Switch to it for the next launch.")
        }
    }
    private func activate(_ profile: ContainerProfile) {
        guard let id = profile.id, let store else { return }
        requestSwitch(model.tr("切换游戏容器", "Switch game container")) {
            let fixture = model.testing
            try await store.activate(id, requireIdle: { if !fixture { try GameContainers.requireIdle() } })
            notice = model.tr("下次启动使用“\(title(profile))”。", "Next launch uses “\(title(profile))”.")
        }
    }
    private func requestSwitch(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        let action = SwitchAction(title: title, apply: work)
        if model.steamRunning { switchAction = action }
        else { apply(action, quitSteam: false) }
    }
    private func apply(_ action: SwitchAction, quitSteam: Bool) {
        perform(action.title) {
            if quitSteam { try await stopSteam() }
            try await action.apply()
            if quitSteam { try await model.launchPreparedSteam() }
        }
    }
    private func stopSteam() async throws {
        model.quitSteamForPreparation()
        for _ in 0..<60 where model.steamRunning { try await Task.sleep(for: .milliseconds(500)) }
        try GameContainers.requireIdle()
    }
    private func perform(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        model.run(title, cancellable: false) { defer { model.refresh() }; try await work() }
    }
    private func runTool(_ command: String, _ container: GameContainer) {
        perform(model.tr("打开容器工具", "Open container tool")) {
            model.runningTools.append(try await GameContainers.launch(container, command: command, paths: model.paths))
        }
    }
    private func chooseExecutable(_ container: GameContainer) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let file = panel.url {
            guard ["exe", "msi"].contains(file.pathExtension.lowercased()) else { model.fail(AppFailure(model.tr("请选择 EXE 或 MSI 文件。", "Choose an EXE or MSI file."))); return }
            runTool(file.path, container)
        }
    }
}
