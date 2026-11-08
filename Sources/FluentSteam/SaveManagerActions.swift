import Foundation
import AppKit
import FluentCore

enum SaveManagerSection: String, CaseIterable { case games, cloud, history }

extension AppModel {
    var managedSaveGames: [ManagedSaveGame] { SaveManagement.catalog(games: games, locations: saves, state: saveManagerState) }
    func refreshSaveManager() {
        do {
            saveManagerState = try SaveManagerStore.load(paths: paths)
            let custom = SaveManagement.customLocations(saveManagerState)
            var seen = Set<String>()
            saves = (saves.filter { $0.kind != "Custom" } + custom).filter { seen.insert("\($0.appID):\($0.id)").inserted }
        } catch { saveManagerStatus = error.localizedDescription }
    }
    func performSaveBackup(_ save: SaveLocation, parent: URL) {
        let target = parent.appendingPathComponent("\(save.appID)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        run(tr("备份并校验存档", "Back up and verify saves"), cancellable: false) {
            let count = try await Task.detached { try Saves.backup(save.url, to: target) }.value
            let warning = await self.recordSaveBackup(save, directory: target, reason: "manual", knownCount: count)
            self.saveManagerStatus = self.tr("已备份并校验 \(count) 个文件：", "Backed up and verified \(count) files: ") + target.path + (warning.map { "\n" + $0 } ?? "")
            self.log("SHA-256 verified: \(count) files"); self.refresh()
        }
    }
    func recordSaveBackup(_ save: SaveLocation, directory: URL, reason: String, knownCount: Int? = nil) async -> String? {
        let paths = paths
        do {
            try await Task.detached {
                let count = try knownCount ?? Saves.verifyBackup(directory).count
                try SaveManagerStore.recordBackup(.init(appID: save.appID, source: save.url, directory: directory, fileCount: count, reason: reason), paths: paths)
            }.value
            return nil
        } catch {
            let warning = tr("备份文件已保留，但历史登记失败，请保留此路径：", "Backup files retained, but history registration failed; keep this path: ") + directory.path + "\n" + error.localizedDescription
            log(warning); return warning
        }
    }
    func saveGameOptions(_ options: GameSaveOptions, appID: Int) {
        let paths = paths
        run(tr("保存游戏存档设置", "Save game save settings")) {
            try await Task.detached { try SaveManagerStore.saveOptions(options, appID: appID, paths: paths) }.value
            self.saveManagerStatus = self.tr("此游戏的目录与备份设置已保存；未移动或修改存档。", "Folder and backup preferences saved for this game; no save files moved or changed.")
            self.refresh()
        }
    }
    func setGameCloudSelection(_ selected: Bool, appID: Int) {
        let paths = paths
        run(tr("保存游戏云存档设置", "Save game cloud settings"), cancellable: false) {
            guard !self.steamRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
            let current = try CloudConfiguration.load(paths: paths)
            let changed = try SaveManagement.settingCloudSelection(selected, appID: appID, config: current, paths: paths)
            var inventory: CloudSaveInventory?
            if changed.enabled {
                let ids = try changed.selectedApps(paths: paths)
                let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Cloud/FluentCloudCLI")
                let output = try await CloudEngine.run(["scan-local-saves", ids.map(String.init).joined(separator: ",")], executable: engine, paths: paths)
                inventory = try CloudOnline.decodeLast(CloudSaveInventory.self, from: output)
            }
            let scanned = inventory
            _ = try await Task.detached { try CloudActivation.save(changed, inventory: scanned, paths: paths) }.value
            self.needsRestart = true
            self.saveManagerStatus = self.tr("此游戏的接管范围已保存；重启 Steam 后生效。没有上传或还原游戏存档。", "This game's scope setting was saved; restart Steam to apply. No game save was uploaded or restored.")
            self.refresh()
        }
    }
}
