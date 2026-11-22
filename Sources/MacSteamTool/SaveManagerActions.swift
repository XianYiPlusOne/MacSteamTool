import Foundation
import AppKit
import MacSteamToolCore

enum SaveManagerSection: String, CaseIterable { case games, history }

extension AppModel {
    var managedSaveGames: [ManagedSaveGame] { SaveManagement.catalog(games: games, locations: saves, state: saveManagerState, metadata: saveGameMetadata, language: language) }
    func refreshSaveManager() {
        do {
            saveManagerState = try SaveManagerStore.load(paths: paths)
            saveGameMetadata = try SaveGameMetadataStore.remember(paths: paths, games: games)
            let custom = SaveManagement.customLocations(saveManagerState)
            var seen = Set<String>()
            saves = (saves.filter { $0.kind != "Custom" } + custom).filter { seen.insert("\($0.appID):\($0.id)").inserted }
        } catch { saveManagerStatus = error.localizedDescription }
    }
    func rememberSaveMetadata(_ items: [GameMetadata], language: String, localNames: [Int: String] = [:]) {
        do {
            let records = try SaveGameMetadataStore.remember(paths: paths, localized: items, language: language, localNames: localNames)
            if records != saveGameMetadata { saveGameMetadata = records }
        } catch { saveManagerStatus = error.localizedDescription }
    }

    func loadSaveMetadata(ids: Set<Int>, cached: [Int: GameMetadata], language: String, current: @MainActor () -> Bool) async {
        rememberSaveMetadata(ids.compactMap { cached[$0] }, language: language)
        let missing = ids.filter { saveGameMetadata[$0]?.displayName(language: language) == nil }
        guard !missing.isEmpty else { return }
        let alternate = language == "english" ? "schinese" : "english"
        let other = await api.cached(language: alternate)
        guard current() else { return }
        rememberSaveMetadata(missing.compactMap { other[$0] }, language: alternate)
        let unresolved = missing.filter { saveGameMetadata[$0]?.displayName(language: language) == nil }
        let diskNames = await api.cachedAppNames(ids: unresolved)
        let steamNames = await SaveGameMetadataStore.steamNames(ids: unresolved.subtracting(diskNames.keys), paths: paths)
        guard current() else { return }
        rememberSaveMetadata([], language: language, localNames: diskNames.merging(steamNames) { first, _ in first })
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
}
