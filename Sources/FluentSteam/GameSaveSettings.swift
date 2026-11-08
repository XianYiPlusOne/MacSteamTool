import SwiftUI
import AppKit
import FluentCore

struct GameSaveSettings: View {
    @EnvironmentObject var model: AppModel
    let game: ManagedSaveGame
    @ViewState<GameSaveOptions> private var options = .init()
    @ViewState<GameSaveOptions> private var savedOptions = .init()
    @ViewState<CloudConfiguration> private var cloud = .init()
    @ViewState<Bool> private var selected = false
    @ViewState<Bool> private var savedSelection = false
    @ViewState<Bool> private var eligible = false
    @ViewState<String> private var cloudError = ""
    @ViewState<Bool> private var confirmCloud = false
    @ViewState<Bool> private var applyingCloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel {
                Label(model.tr("备份位置", "Backup destination"), systemImage: "externaldrive").font(.headline)
                Text(model.tr("仅用于此游戏的手动备份；留空则每次询问。每次备份都会创建独立副本，不覆盖已有备份。", "Used only for this game's manual backups. Leave empty to choose each time. Each backup creates a separate copy.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(model.tr("每次备份时选择…", "Ask each time…"), text: $options.backupDirectory).textFieldStyle(.roundedBorder).accessibilityIdentifier("save-backup-directory")
                    Button(model.tr("选择…", "Choose…")) { if let url = chooseFolder() { options.backupDirectory = url.path } }
                    Button(model.tr("重置", "Reset")) { options.backupDirectory = "" }.disabled(options.backupDirectory.isEmpty)
                }
            }
            Panel {
                HStack {
                    Label(model.tr("自定义存档目录", "Custom save folders"), systemImage: "folder.badge.plus").font(.headline)
                    Spacer()
                    Button(model.tr("添加目录…", "Add folder…")) {
                        if let url = chooseFolder(), !options.customFolders.contains(url.path) { options.customFolders.append(url.path) }
                    }
                }
                Text(model.tr("关联此游戏实际使用的存档文件夹。这里只用于本地备份与恢复，不会移动文件，也不会自动把该目录上传到云端。", "Link the folder this game actually uses. This enables local backup and restore only; it does not move files or automatically upload the folder.")).font(.caption).foregroundStyle(.secondary)
                if options.customFolders.isEmpty { Text(model.tr("尚未添加自定义目录", "No custom folders added")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                ForEach(options.customFolders, id: \.self) { path in
                    HStack {
                        Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button { options.customFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .help(model.tr("仅移除关联，不删除文件", "Unlink only; do not delete files"))
                    }
                }
            }
            HStack {
                Text(model.tr("设置仅对当前游戏生效；移除目录只取消关联。", "Settings apply only to this game. Removing a folder only unlinks it.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.tr("保存目录设置", "Save folder settings")) { model.saveGameOptions(options, appID: game.id) }
                    .buttonStyle(.borderedProminent).disabled(model.busy || options == savedOptions).accessibilityIdentifier("save-folder-settings")
            }
            Divider()
            Panel {
                HStack {
                    Label(model.tr("此游戏的云存档范围", "Cloud scope for this game"), systemImage: "icloud").font(.headline)
                    Spacer(); SaveManagerShortcut(section: .cloud)
                }
                Text(cloudDescription).font(.caption).foregroundStyle(.secondary)
                Toggle(model.tr("由 Fluent 接管此游戏的存档接口", "Redirect this game's save API through Fluent"), isOn: $selected)
                    .disabled(model.busy || model.steamRunning || !cloudError.isEmpty || (!eligible && !savedSelection))
                    .accessibilityIdentifier("save-game-cloud-toggle")
                Text(model.tr("这是 Fluent 重定向设置，不是 Steam 官方云开关。仅影响接管范围，不修改其他游戏、成就或时长设置。", "This is Fluent redirection, not the official Steam Cloud switch. It changes only this game's scope, not other games, achievements or playtime settings.")).font(.caption).foregroundStyle(.secondary)
                if !eligible && cloud.automaticApps { Text(model.tr("自动模式只支持 macSteam 已启用的主游戏。", "Automatic mode supports enabled macSteam base games only.")).font(.caption).foregroundStyle(Palette.amber) }
                if !cloudError.isEmpty { Text(cloudError).font(.caption).foregroundStyle(.red) }
                HStack {
                    if model.steamRunning { Label(model.tr("退出 Steam 后才能修改接管范围", "Quit Steam to change scope"), systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(model.tr("应用接管范围…", "Apply scope…")) { confirmCloud = true }
                        .disabled(model.busy || model.steamRunning || !cloudError.isEmpty || selected == savedSelection)
                }
            }
        }
        .onAppear { reloadOptions(); reloadCloud() }
        .onChange(of: model.saveManagerState.options(for: game.id)) { _, _ in reloadOptions() }
        .onChange(of: model.lastRefresh) { _, _ in if selected == savedSelection { reloadCloud() } }
        .onChange(of: model.busy) { _, busy in if !busy && applyingCloud { applyingCloud = false; reloadCloud() } }
        .confirmationDialog(model.tr("应用此游戏的接管范围？", "Apply this game's scope?"), isPresented: $confirmCloud) {
            Button(model.tr("应用", "Apply")) { applyingCloud = true; model.setGameCloudSelection(selected, appID: game.id) }
        } message: {
            Text(model.tr("启用接管时会先备份检测到的存档。此操作不会开启全局同步、替换服务商或恢复存档；需重启 Steam 生效。", "Detected saves are backed up before enabling redirection. This does not enable global sync, change providers or restore saves. Restart Steam to apply."))
        }
    }
    private var cloudDescription: String {
        if !cloud.enabled { return model.tr("全局接管未开启。此处只保存游戏范围，不会自动启动云同步。", "Global redirection is off. This saves scope only; it does not start cloud sync.") }
        if [.local, .folder].contains(cloud.provider) { return model.tr("当前服务为本地存储，并不代表已上传到互联网。", "The current provider is local storage; this does not mean files are uploaded online.") }
        return model.tr("已配置服务：", "Configured provider: ") + cloud.provider.title + model.tr("。是否同步成功请在云服务页检查，不能仅根据此开关判断。", ". Check the cloud services page for sync results; this switch alone does not confirm successful sync.")
    }
    private func reloadOptions() { options = model.saveManagerState.options(for: game.id); savedOptions = options }
    private func reloadCloud() {
        do {
            cloud = try CloudConfiguration.load(paths: model.paths)
            savedSelection = try SaveManagement.cloudSelection(cloud, appID: game.id, paths: model.paths)
            selected = savedSelection
            eligible = (try? SaveManagement.settingCloudSelection(true, appID: game.id, config: cloud, paths: model.paths)) != nil
            cloudError = ""
        } catch { cloudError = error.localizedDescription }
    }
    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
