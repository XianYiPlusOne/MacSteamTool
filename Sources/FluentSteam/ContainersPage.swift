import SwiftUI
import AppKit
import FluentCore

struct ContainersPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<[GameContainer]> private var containers = []
    @ViewState<[ContainerBackend]> private var backends = []
    @ViewState<[InstalledGame]> private var installed = []
    @ViewState<Int> private var gameID = 0
    @ViewState<String> private var backendID = ""
    @ViewState<String> private var search = ""
    @ViewState<GameContainer?> private var pending = nil
    @ViewState<Bool> private var resetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("容器管理", "Game containers"), subtitle: model.tr("每款游戏有独立的 Windows 环境，分别保存组件、注册表和容器内存档。Wine 与 CrossOver 容器分开管理。", "Each game has its own Windows environment, with separate components, registry and in-container saves. Wine and CrossOver containers are managed separately.")) {
                Button(model.tr("刷新", "Refresh"), action: reload).disabled(model.busy)
            }
            if model.steamRunning {
                Label(model.tr("请退出 Steam 后创建或修改容器；也请关闭该容器中的游戏和工具。", "Quit Steam before creating or modifying containers, and close that container's games and tools."), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            Panel {
                Text(model.tr("为游戏创建独立容器", "Create a container for a game")).font(.headline)
                if installed.isEmpty {
                    Text(model.tr("请先在 Steam 下载游戏，安装后即可为它创建容器。", "Download a game in Steam first, then create its container here.")).font(.callout).foregroundStyle(.secondary)
                } else if backends.isEmpty {
                    Text(model.tr("请先在运行环境中选择 Wine 或 CrossOver。", "Choose Wine or CrossOver in Runtime first.")).font(.callout)
                    Button(model.tr("选择兼容层", "Choose backend")) { model.page = .runtime }
                } else {
                    Picker(model.tr("游戏", "Game"), selection: $gameID) {
                        ForEach(installed, id: \.id) { Text("\($0.name) · \($0.id)").tag($0.id) }
                    }
                    Picker(model.tr("兼容层", "Backend"), selection: $backendID) {
                        ForEach(backends) { Text($0.name).tag($0.id) }
                    }
                    Text(model.tr("每款游戏可各保留一个 Wine 容器和一个 CrossOver 容器。创建后仅为此游戏选择兼容层；游戏安装文件不变。", "Each game can keep one Wine container and one CrossOver container. Creation selects the backend only for this game and keeps installed game files intact.")).font(.caption).foregroundStyle(.secondary)
                    Button(model.tr("创建并用于此游戏", "Create & use for this game"), action: create).buttonStyle(.borderedProminent).disabled(model.busy || model.steamRunning || gameID == 0 || backendID.isEmpty)
                }
            }
            HStack {
                TextField(model.tr("搜索游戏名或 AppID", "Search game name or AppID"), text: $search).textFieldStyle(.roundedBorder)
                if model.containerAppID != nil { Button(model.tr("显示全部容器", "Show all containers")) { model.containerAppID = nil; search = "" } }
            }
            let visible = containers.filter { (model.containerAppID == nil || $0.appID == model.containerAppID) && (search.isEmpty || name($0).localizedCaseInsensitiveContains(search) || String($0.appID).contains(search)) }
            if visible.isEmpty {
                Panel { EmptyMessage(icon: "shippingbox", title: model.tr("暂无容器", "No containers"), detail: model.tr("可在上方提前创建；首次通过 Steam 启动 Windows 游戏时也会自动创建。", "Create one above, or let Steam create it on the first launch of a Windows game.")) }
            }
            ForEach(visible) { container in containerRow(container) }
        }
        .onAppear(perform: reload)
        .onChange(of: model.busy) { _, busy in if !busy { reload() } }
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
                    Button(model.tr("用于此游戏", "Use for this game")) {
                        guard let backend else { return }
                        perform(model.tr("选择游戏容器", "Select game container")) { _ = try SteamCompatibility.save(paths: model.paths, appID: container.appID, tool: backend.id) }
                    }.disabled(model.busy || model.steamRunning || backend == nil || !container.ready)
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
    private func reload() {
        do {
            installed = SteamLibrary.installed(model.paths); backends = try GameContainers.backends(model.paths)
            containers = GameContainers.all(model.paths) + GameContainers.recoverable(model.paths)
            if let selected = model.containerAppID, installed.contains(where: { $0.id == selected }) { gameID = selected }
            else if !installed.contains(where: { $0.id == gameID }) { gameID = installed.first?.id ?? 0 }
            if !backends.contains(where: { $0.id == backendID }) { backendID = backends.first?.id ?? "" }
        } catch { model.fail(error) }
    }
    private func create() {
        guard let game = installed.first(where: { $0.id == gameID }), let backend = backends.first(where: { $0.id == backendID }) else { return }
        let container = GameContainer(appID: game.id, library: game.library, isWine: backend.isWine)
        perform(model.tr("创建独立游戏容器", "Create game container")) {
            try await GameContainers.create(container, backend: backend, paths: model.paths)
            _ = try SteamCompatibility.save(paths: model.paths, appID: game.id, tool: backend.id)
        }
    }
    private func perform(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        model.run(title, cancellable: false) { defer { reload(); model.refresh() }; try await work() }
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
