import SwiftUI
import AppKit
import MacSteamToolCore

struct GameSaveSettings: View {
    @EnvironmentObject var model: AppModel
    let game: ManagedSaveGame
    @ViewState<GameSaveOptions> private var options = .init()
    @ViewState<GameSaveOptions> private var savedOptions = .init()
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
                Text(model.tr("选择此游戏的存档文件夹，用于本地备份与恢复。", "Choose the folders this game uses for local backup and restore.")).font(.caption).foregroundStyle(.secondary)
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
        }
        .onAppear { reloadOptions() }
        .onChange(of: model.saveManagerState.options(for: game.id)) { _, _ in reloadOptions() }
    }
    private func reloadOptions() { options = model.saveManagerState.options(for: game.id); savedOptions = options }
    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
