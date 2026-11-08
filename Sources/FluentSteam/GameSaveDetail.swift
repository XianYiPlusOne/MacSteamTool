import SwiftUI
import FluentCore

struct GameSaveDetail: View {
    @EnvironmentObject var model: AppModel
    let game: ManagedSaveGame
    @ViewState<String> private var tab = "files"
    @ViewState<String> private var location = ""
    private var selected: SaveLocation? { game.locations.first(where: { $0.id == location }) ?? game.locations.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.icloud").font(.system(size: 27)).foregroundStyle(Palette.accent).padding(14).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.name).font(.title2.bold()).lineLimit(2).accessibilityIdentifier("save-manager-game-title")
                        Text("AppID \(game.id) · " + model.tr("\(game.locations.count) 个目录 · \(game.backupCount) 份备份", "\(game.locations.count) folders · \(game.backupCount) backups")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Picker("", selection: $tab) {
                    Text(model.tr("存档目录", "Save folders")).tag("files")
                    Text(model.tr("备份记录", "Backup history")).tag("backups")
                    Text(model.tr("游戏设置", "Game settings")).tag("settings")
                }.pickerStyle(.segmented).accessibilityIdentifier("game-save-tabs")
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "files" {
                        if let selected {
                            Panel {
                                Text(model.tr("选择要管理的目录", "Choose a folder")).font(.headline)
                                Picker(model.tr("存档目录", "Save folder"), selection: $location) {
                                    ForEach(game.locations) { save in Text(locationLabel(save)).tag(save.id) }
                                }.labelsHidden().frame(maxWidth: .infinity).accessibilityIdentifier("save-folder-picker")
                                Text(selected.url.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Divider()
                                HStack {
                                    Button(model.tr("打开目录", "Open folder")) { model.openFolder(selected.url) }
                                    Spacer()
                                    Button(model.tr("备份并校验…", "Back up & verify…")) { model.backupSave(selected) }.buttonStyle(.borderedProminent).disabled(model.busy)
                                    Menu(model.tr("恢复 / 清空", "Restore / clear")) {
                                        Button(model.tr("从已有备份恢复…", "Restore an existing backup…")) { model.restoreSave(selected) }
                                        Divider()
                                        Button(model.tr("备份后清空…", "Back up and clear…"), role: .destructive) { model.clearSave(selected) }
                                    }.disabled(model.busy || model.steamRunning)
                                }
                            }
                            if selected.kind.hasPrefix("NotProton") {
                                Label(model.tr("这是 NotProton 的候选用户目录，可能含有其他数据。建议在“游戏设置”中添加具体的存档子目录，不要直接清空整个用户目录。", "This is a candidate NotProton user folder and may contain other data. Add the specific save subfolder in Game settings; do not clear an entire user folder."), systemImage: "info.circle").font(.caption).foregroundStyle(Palette.amber)
                            }
                            Panel {
                                Label(model.tr("操作只针对当前选中的目录", "Actions apply only to the selected folder"), systemImage: "checkmark.shield").font(.subheadline.bold())
                                Text(model.tr("备份会逐文件校验。恢复和清空需要退出游戏与 Steam，并先保留当前内容的回退副本。", "Backups are checked file by file. Quit the game and Steam before restoring or clearing; current files are preserved in a recovery copy first.")).font(.caption).foregroundStyle(.secondary)
                                Button(model.tr("查看此游戏的备份记录", "View this game's backup history")) { tab = "backups" }
                            }
                        } else {
                            EmptyMessage(icon: "folder.badge.plus", title: model.tr("还没有检测到存档目录", "No save folder detected"), detail: model.tr("游戏可能尚未创建存档，或使用了自定义路径。可以手动关联目录，不必先开启游戏。", "The game may not have created saves or may use a custom path. Add its folder without launching the game."))
                            HStack { Spacer(); Button(model.tr("添加存档目录", "Add a save folder")) { tab = "settings" }.buttonStyle(.borderedProminent); Spacer() }
                        }
                    } else if tab == "backups" {
                        GameSaveBackupList(game: game)
                    } else {
                        GameSaveSettings(game: game)
                    }
                    if !model.saveManagerStatus.isEmpty { Text(model.saveManagerStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let message = model.message { Text(message.detail).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(22)
            }
        }
        .onAppear { location = game.locations.first?.id ?? "" }
        .onChange(of: game.locations.map(\.id)) { _, ids in if !ids.contains(location) { location = ids.first ?? "" } }
    }
    private func locationLabel(_ save: SaveLocation) -> String {
        if save.kind == "Steam remote" { return "Steam · " + model.tr("账号 ", "Account ") + save.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
        let kind = save.kind == "Custom" ? model.tr("自定义目录", "Custom folder") : save.kind
        return kind + " · " + save.url.deletingLastPathComponent().lastPathComponent + "/" + save.url.lastPathComponent
    }
}

struct GameSaveBackupList: View {
    @EnvironmentObject var model: AppModel
    let game: ManagedSaveGame
    @ViewState<Int> private var page = 0
    private var records: [GameSaveBackup] { model.saveManagerState.backups(for: game.id) }
    private var pages: Int { max(1, (records.count + 5) / 6) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.tr("只显示此游戏的备份", "Backups for this game only")).font(.headline)
            Text(model.tr("备份创建时已校验；恢复前会重新检查文件。旧版导出的备份仍可在“存档目录”中手动选择恢复。", "Backups were verified when created and are checked again before restoration. Older exported backups can still be selected from Save folders.")).font(.caption).foregroundStyle(.secondary)
            if records.isEmpty {
                EmptyMessage(icon: "clock.arrow.circlepath", title: model.tr("还没有备份记录", "No backup history yet"), detail: model.tr("在存档目录页创建备份后，记录会出现在这里。", "Create a backup from Save folders to see it here."))
            }
            ForEach(Array(records.dropFirst(min(page, pages - 1) * 6).prefix(6))) { backup in
                Panel(padding: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(backup.created.formatted()).font(.subheadline.bold())
                            Text(reason(backup) + " · " + model.tr("\(backup.fileCount) 个文件", "\(backup.fileCount) files")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.tr("打开", "Open")) { model.openFolder(URL(fileURLWithPath: backup.directory)) }.disabled(!exists(backup))
                        Button(model.tr("恢复…", "Restore…")) {
                            model.restoreSave(SaveLocation(appID: game.id, kind: "Backup target", url: URL(fileURLWithPath: backup.source)), backup: URL(fileURLWithPath: backup.directory))
                        }.disabled(!exists(backup) || model.busy || model.steamRunning)
                    }
                    Text(backup.directory).font(.system(size: 10, design: .monospaced)).lineLimit(2).textSelection(.enabled).foregroundStyle(.secondary)
                    if !exists(backup) { Label(model.tr("备份目录暂不可用，请检查外置磁盘。", "Backup unavailable; check external drives."), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.amber) }
                }
            }
            if pages > 1 {
                HStack { Spacer(); Button(model.tr("上一页", "Previous")) { page -= 1 }.disabled(page == 0); Text("\(min(page, pages - 1) + 1) / \(pages)").font(.caption); Button(model.tr("下一页", "Next")) { page += 1 }.disabled(page >= pages - 1) }
            }
        }.onChange(of: pages) { _, count in page = min(page, count - 1) }
    }
    private func exists(_ backup: GameSaveBackup) -> Bool { FileStore.fm.fileExists(atPath: backup.directory + "/.fluent-checksums.json") }
    private func reason(_ backup: GameSaveBackup) -> String {
        switch backup.reason { case "before-restore": model.tr("恢复前回退副本", "Before restoration"); case "before-clear": model.tr("清空前回退副本", "Before clearing"); default: model.tr("手动备份", "Manual backup") }
    }
}
