import SwiftUI
import AppKit
import FluentCore

struct SaveManagerShortcut: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var appID: Int?
    var section: SaveManagerSection = .games
    var compact = false
    var body: some View {
        Button {
            if let appID { model.saveManagerGameID = appID }
            model.saveManagerSection = section
            openWindow(id: "save-manager")
        } label: {
            if compact { Image(systemName: "externaldrive.badge.icloud") }
            else { Label(title, systemImage: section == .cloud ? "icloud" : section == .history ? "clock.arrow.circlepath" : "externaldrive.badge.icloud") }
        }
        .help(title).accessibilityLabel(title)
        .accessibilityIdentifier(appID.map { "manage-saves-\($0)" } ?? "open-save-manager")
    }
    private var title: String {
        switch section {
        case .games: model.tr("管理存档", "Manage saves")
        case .cloud: model.tr("云服务设置", "Cloud settings")
        case .history: model.tr("配置历史", "Configuration history")
        }
    }
}

struct SaveManagerWindow: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var search = ""
    private var games: [ManagedSaveGame] { SaveManagement.filtered(model.managedSaveGames, query: search, onlyWithSaves: false) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.tr("存档管理", "Save manager"), systemImage: "externaldrive.badge.icloud").font(.headline)
                Spacer()
                Picker("", selection: $model.saveManagerSection) {
                    Text(model.tr("游戏存档", "Game saves")).tag(SaveManagerSection.games)
                    Text(model.tr("云服务", "Cloud services")).tag(SaveManagerSection.cloud)
                    Text(model.tr("配置历史", "Config history")).tag(SaveManagerSection.history)
                }.pickerStyle(.segmented).frame(width: 360).accessibilityIdentifier("save-manager-sections")
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(model.tr("刷新存档", "Refresh saves")).disabled(model.busy)
            }.padding(18)
            Divider()
            Group {
                switch model.saveManagerSection {
                case .games:
                    HSplitView {
                        VStack(spacing: 8) {
                            HStack { Image(systemName: "magnifyingglass"); TextField(model.tr("搜索游戏或 AppID", "Game name or AppID"), text: $search).textFieldStyle(.plain) }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).padding([.horizontal, .top], 12)
                            List(selection: $model.saveManagerGameID) {
                                ForEach(games) { game in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(game.name).lineLimit(1)
                                        Text("App \(game.id) · " + model.tr("\(game.locations.count) 个目录", "\(game.locations.count) folders")).font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 5).tag(game.id)
                                }
                            }.listStyle(.sidebar).accessibilityIdentifier("save-manager-game-list")
                            Text(model.tr("\(games.count) 款游戏", "\(games.count) games")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                        }.frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
                        if let game = model.managedSaveGames.first(where: { $0.id == model.saveManagerGameID }) {
                            GameSaveDetail(game: game).id(game.id).frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            EmptyMessage(icon: "externaldrive", title: model.tr("选择一款游戏", "Select a game"), detail: model.tr("在左侧选择游戏，管理目录、备份和同步设置。", "Choose a game to manage its folders, backups and sync preferences.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                case .cloud:
                    ScrollView { CloudPanel().padding(22) }
                case .history:
                    ConfigurationHistoryPanel().padding(22)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small); Text(model.progress) }
                else { Image(systemName: "checkmark.shield"); Text(model.tr("仅操作所选目录；恢复或清空前先备份。", "Actions target the selected folder; back up before restoring or clearing.")) }
                Spacer()
                if model.steamRunning { Label(model.tr("Steam 运行中：恢复与同步设置已锁定", "Steam running: restore & sync settings locked"), systemImage: "lock") }
            }.font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(Palette.accent)
        .task { await model.bootstrap(); selectDefault() }
        .onChange(of: model.managedSaveGames.map(\.id)) { _, _ in selectDefault() }
        .onChange(of: model.saveManagerGameID) { _, id in if !games.contains(where: { $0.id == id }) { search = "" } }
    }
    private func selectDefault() {
        if !model.managedSaveGames.contains(where: { $0.id == model.saveManagerGameID }) { model.saveManagerGameID = model.managedSaveGames.first?.id }
    }
}

struct ConfigurationHistoryPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<BackupRecord?> private var restore: BackupRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.tr("配置历史", "Configuration history")).font(.title2.bold())
                    Text(model.tr("这是应用与入库配置的回退记录，不是游戏进度备份。", "These are configuration rollback records, not game-progress backups.")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Button(model.tr("打开目录", "Open folder")) { model.openFolder(model.paths.backups) }
            }
            if model.backups.isEmpty { EmptyMessage(icon: "clock.arrow.circlepath", title: model.tr("暂无配置备份", "No configuration backups"), detail: model.tr("修改配置后会自动记录。", "Configuration changes create backups automatically.")) }
            else {
                List(model.backups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(backup.reason); Text(backup.date.formatted() + " · \(backup.files.count) files").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button(model.tr("还原…", "Restore…")) { restore = backup }.disabled(model.busy || model.steamRunning)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.confirmationDialog(model.tr("还原所选配置？当前配置会再次备份。", "Restore this configuration? Current configuration will be backed up first."), isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } })) {
            Button(model.tr("确认还原", "Restore")) { if let restore { model.restore(restore) }; restore = nil }
        }
    }
}
