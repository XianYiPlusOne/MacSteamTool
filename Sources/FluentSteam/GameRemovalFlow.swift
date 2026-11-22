import SwiftUI
import FluentCore

struct RemovalRequest: Identifiable {
    let id = UUID()
    let games: [Game]
    let plans: [GameRemovalPlan]
    let problem: String?
}
struct SaveRecoveryRequest: Identifiable {
    let id = UUID()
    let appIDs: [Int]
    var backups: [GameSaveBackup]
    var containers: [ContainerBackup] = []
}

extension AppModel {
    func requestGameRemoval(_ games: [Game]) {
        guard !busy, !games.isEmpty else { return }
        selectedGame = nil
        do { removalRequest = RemovalRequest(games: games, plans: try games.map { try GameRemoval.plan(game: $0, paths: paths) }, problem: nil) }
        catch { removalRequest = RemovalRequest(games: games, plans: [], problem: error.localizedDescription) }
    }
    func confirmGameRemoval(deleteFiles: Bool) {
        guard !busy, let request = removalRequest else { return }
        if deleteFiles && (request.problem != nil || steamRunning) { return }
        removalRequest = nil
        run(tr("删除游戏", "Remove game"), cancellable: false) {
            try SaveGameMetadataStore.remember(paths: self.paths, games: request.games,
                localized: request.games.compactMap { self.metadata[$0.id] }, language: self.language)
            for game in request.games { try await self.covers.retainCached(appID: game.id, steam: self.paths.steam) }
            if deleteFiles {
                let fixture = self.testing
                var completed = 0
                do {
                    for plan in request.plans {
                        let retained = try await GameRemoval.perform(plan, paths: self.paths, requireIdle: {
                            if !fixture { try GameContainers.requireIdle() }
                        })
                        completed += 1
                        if !retained.isEmpty { self.log(self.tr("未能移入废纸篓，文件保留在：", "Could not move to Trash; retained at: ") + retained.map(\.path).joined(separator: "\n")) }
                    }
                } catch {
                    self.refresh()
                    throw AppFailure(self.tr("已完成 \(completed)/\(request.games.count) 个游戏。", "Completed \(completed)/\(request.games.count) games. ") + error.localizedDescription)
                }
            } else { try self.service.batch(request.games, action: .remove) }
            self.needsRestart = true; self.refresh()
        }
    }
    func offerSaveRecovery(_ ids: [Int]) {
        do {
            let records = try SaveRecovery.latest(appIDs: ids, paths: paths)
            guard !records.isEmpty || !GameContainers.removalBackups(appIDs: ids, paths: paths).isEmpty else { return }
            let combined = Array(Set(ids + (saveRecoveryRequest?.appIDs ?? []))).sorted()
            saveRecoveryRequest = SaveRecoveryRequest(appIDs: combined, backups: try SaveRecovery.latest(appIDs: combined, paths: paths), containers: GameContainers.removalBackups(appIDs: combined, paths: paths))
            remindedSaveApps.formUnion(ids)
        } catch { log(error.localizedDescription) }
    }
    func remindSaveRecoveryIfReady() {
        guard !busy, !steamRunning, pendingImport == nil, saveRecoveryRequest == nil, removalRequest == nil else { return }
        let ids = (saveManagerState.pendingReinstallRestores ?? []).filter { !remindedSaveApps.contains($0) }
        for id in ids {
            guard games.contains(where: { $0.id == id && $0.enabled }),
                  let backups = try? SaveRecovery.latest(appIDs: [id], paths: paths),
                  backups.contains(where: { (try? SaveRecovery.destination($0, paths: paths)) != nil }) ||
                  (!GameContainers.removalBackups(appIDs: [id], paths: paths).isEmpty && (try? SaveRecovery.installedGame(id, paths: paths)) != nil) else { continue }
            offerSaveRecovery([id])
        }
    }
    func deferSaveRecovery(_ later: Bool) {
        guard !busy, let request = saveRecoveryRequest else { return }
        do {
            try SaveManagerStore.remindAfterInstall(request.appIDs, enabled: later, paths: paths)
            if later {
                for id in request.appIDs {
                    let readySave = request.backups.contains { $0.appID == id && (try? SaveRecovery.destination($0, paths: paths)) != nil }
                    let readyContainer = request.containers.contains { $0.appID == id && (try? SaveRecovery.installedGame(id, paths: paths)) != nil }
                    if steamRunning || !(readySave || readyContainer) { remindedSaveApps.remove(id) }
                }
            }
            saveRecoveryRequest = nil
            refreshSaveManager()
        } catch { fail(error) }
    }
    func importRecoveredContainer(_ backup: ContainerBackup) {
        guard !busy, !steamRunning else { return }
        let paths = paths, fixture = testing
        run(tr("恢复容器与存档", "Restore container and saves"), cancellable: false) {
            try await SaveRecovery.restoreContainer(backup, paths: paths, requireIdle: { if !fixture { try GameContainers.requireIdle() } })
            self.saveRecoveryRequest?.containers.removeAll { $0.id == backup.id }
            let marker = "/steamapps/compatdata/\(backup.appID)/" + (backup.isWine ? "fluent-free/pfx/" : "pfx/")
            self.saveRecoveryRequest?.backups.removeAll { $0.appID == backup.appID && $0.source.contains(marker) }
            if self.saveRecoveryRequest?.backups.isEmpty == true && self.saveRecoveryRequest?.containers.isEmpty == true {
                if let ids = self.saveRecoveryRequest?.appIDs { try SaveManagerStore.remindAfterInstall(ids, enabled: false, paths: paths) }
                self.saveRecoveryRequest = nil
            }
            self.refresh()
        }
    }
    func importRecoveredSave(_ backup: GameSaveBackup) {
        guard !busy, !steamRunning else { return }
        let paths = paths, fixture = testing
        run(tr("恢复游戏存档", "Restore game saves"), cancellable: false) {
            try await Task.detached {
                try await SaveRecovery.restore(backup, paths: paths, requireIdle: { if !fixture { try GameContainers.requireIdle() } })
            }.value
            self.saveRecoveryRequest?.backups.removeAll { $0.id == backup.id }
            if self.saveRecoveryRequest?.backups.isEmpty == true && self.saveRecoveryRequest?.containers.isEmpty == true {
                if let ids = self.saveRecoveryRequest?.appIDs { try SaveManagerStore.remindAfterInstall(ids, enabled: false, paths: paths) }
                self.saveRecoveryRequest = nil
            }
            self.saveManagerStatus = self.tr("存档已恢复；可以启动游戏继续进度。", "Saves restored; launch the game to continue.")
            self.refresh()
        }
    }
}

struct GameRemovalSheet: View {
    @EnvironmentObject var model: AppModel
    let request: RemovalRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.tr("是否同时删除游戏本体？", "Also remove installed game files?")).font(.title2.bold())
            Text(request.games.map(\.name).joined(separator: "、"))
            Text(model.tr("仅移除入库会保留游戏和存档。同时删除会先备份并校验检测到的本地存档、备份容器，再将游戏本体、容器和这些存档目录移入废纸篓。云端存档不会删除。", "Removing entries keeps games and saves. Full removal verifies local save backups and backs up containers, then moves installed games, containers and detected save folders to Trash. Cloud saves are retained.")).font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.plans, id: \.game.id) { plan in
                        Text(plan.game.name).font(.headline)
                        ForEach(plan.targets, id: \.path) { Text($0.path).font(.caption.monospaced()).textSelection(.enabled) }
                        Text(model.tr("检测到 \(plan.saves.count) 个存档目录；未列出的自定义存档请先在存档管理中关联。", "Detected \(plan.saves.count) save folders. Add any unlisted custom saves in Save management first.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let problem = request.problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.steamRunning { Text(model.tr("同时删除前请退出 Steam 和游戏。", "Quit Steam and games before full removal.")).foregroundStyle(.orange) }
            HStack {
                Button(model.tr("取消", "Cancel")) { model.removalRequest = nil }
                Spacer()
                Button(model.tr("仅移除入库", "Remove entries only")) { model.confirmGameRemoval(deleteFiles: false) }
                Button(model.tr("备份存档并删除全部", "Back up saves and remove files"), role: .destructive) { model.confirmGameRemoval(deleteFiles: true) }
                    .disabled(request.problem != nil || model.steamRunning)
            }.disabled(model.busy)
        }.padding(24).frame(width: 760, height: 530).interactiveDismissDisabled(model.busy)
    }
}

struct ReinstallSaveRecoverySheet: View {
    @EnvironmentObject var model: AppModel
    let request: SaveRecoveryRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.tr("发现以前的存档备份", "Previous save backups found")).font(.title2.bold())
            Text(model.tr("是否导入备份，继续以前的游戏进度？每个原目录显示最新备份。恢复前会校验备份，并备份目标目录当前内容。", "Import a backup to continue your progress? The latest backup for each original folder is shown. Backups are verified and current saves are backed up before replacement."))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(request.containers) { backup in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AppID \(backup.appID) · " + (backup.isWine ? "Wine" : "CrossOver")).font(.headline)
                            Text(model.tr("完整容器备份，包含注册表存档和容器设置。恢复会替换整个容器，现有容器会先备份。也可只恢复下方列出的存档目录。", "Full container backup includes registry saves and settings. Restoring replaces the container after backing up the current one. Alternatively, restore individual save folders below.")).font(.caption)
                            Button(model.tr("恢复完整容器与存档", "Restore full container and saves")) { model.importRecoveredContainer(backup) }
                                .disabled(model.busy || model.steamRunning || (try? SaveRecovery.installedGame(backup.appID, paths: model.paths)) == nil)
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(request.backups) { backup in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("AppID \(backup.appID) · \(backup.created.formatted()) · \(backup.fileCount) files").font(.headline)
                            Text(backup.source).font(.caption.monospaced()).textSelection(.enabled)
                            if let target = try? SaveRecovery.destination(backup, paths: model.paths) {
                                Text(model.tr("恢复到：", "Restore to: ") + target.path).font(.caption)
                                Button(model.tr("导入此存档", "Import this save backup")) { model.importRecoveredSave(backup) }.disabled(model.steamRunning || model.busy)
                            } else { Text(model.tr("请先安装游戏并准备对应容器，再恢复此存档。", "Install the game and prepare its container before restoring.")).font(.caption).foregroundStyle(.orange) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if model.steamRunning { Text(model.tr("恢复存档前请退出 Steam 和游戏。", "Quit Steam and games before restoring saves.")).foregroundStyle(.orange) }
            if let message = model.message { Text(message.detail).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(model.tr("暂不恢复", "Not now")) { model.deferSaveRecovery(false) }
                Spacer()
                Button(model.tr("安装和容器就绪后提醒", "Remind me after installation")) { model.deferSaveRecovery(true) }
            }.disabled(model.busy)
        }.padding(24).frame(width: 760, height: 550).interactiveDismissDisabled()
    }
}
