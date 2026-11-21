import Foundation

public enum SaveRecovery {
    public static func latest(appIDs: [Int], paths: AppPaths) throws -> [GameSaveBackup] {
        let state = try SaveManagerStore.load(paths: paths)
        var seen = Set<String>()
        return state.backups.filter { appIDs.contains($0.appID) && $0.fileCount > 0 && $0.reason != "before-restore" }.sorted { $0.created > $1.created }.filter {
            seen.insert("\($0.appID):\($0.source)").inserted
        }
    }
    /// Resolve game-relative folders against the current installation. Never
    /// manufacture an empty Wine prefix before its runtime has initialized it.
    public static func destination(_ backup: GameSaveBackup, paths: AppPaths) throws -> URL {
        let installed = try installedGame(backup.appID, paths: paths)
        let source = URL(fileURLWithPath: backup.source).standardizedFileURL
        let marker = "/steamapps/compatdata/\(backup.appID)/"
        let target: URL
        if let range = source.path.range(of: marker) {
            let suffix = String(source.path[range.upperBound...])
            let wine = suffix.hasPrefix("fluent-free/pfx/")
            let prefix = wine ? "fluent-free/pfx/" : "pfx/"
            guard suffix.hasPrefix(prefix), !suffix.dropFirst(prefix.count).isEmpty,
                  GameContainer(appID: backup.appID, library: installed.library, isWine: wine).ready else {
                throw AppFailure("请先准备此游戏对应的容器，再恢复存档 / Prepare this game's container before restoring saves")
            }
            target = installed.library.appendingPathComponent("steamapps/compatdata/\(backup.appID)/" + suffix)
        } else if let range = source.path.range(of: "/steamapps/common/") {
            let tail = source.path[range.upperBound...].split(separator: "/", maxSplits: 1)
            guard tail.count == 2 else { throw AppFailure("不能把整个游戏安装目录作为存档覆盖 / Cannot overwrite a whole game installation as saves") }
            target = installed.folder.appendingPathComponent(String(tail[1]))
        } else { target = source }
        try GameRemoval.noLinks(target)
        let protected = [paths.data, paths.steam, paths.macSteam, FileManager.default.homeDirectoryForCurrentUser]
        guard target.path != "/", !protected.contains(where: { GameRemoval.contains(target, $0) }),
              !GameRemoval.contains(paths.data, target) else { throw AppFailure("存档恢复目标范围无效 / Invalid save restore target") }
        return target
    }
    public static func installedGame(_ appID: Int, paths: AppPaths) throws -> InstalledGame {
        guard let installed = SteamLibrary.installed(paths).first(where: { $0.id == appID }) else {
            throw AppFailure("请先重新安装游戏，再恢复存档 / Reinstall the game before restoring saves")
        }
        let manifest = installed.library.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        let state = try VDF.parse(FileStore.text(manifest)).object("AppState")
        guard (UInt64(state?.string("StateFlags") ?? "0") ?? 0) & 4 != 0,
              FileStore.fm.fileExists(atPath: installed.folder.path) else {
            throw AppFailure("请等待游戏安装完成 / Wait for the game installation to complete")
        }
        return installed
    }
    public static func restoreContainer(_ backup: ContainerBackup, paths: AppPaths,
        requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle) async throws {
        let game = try installedGame(backup.appID, paths: paths)
        guard GameContainers.removalBackups(appIDs: [backup.appID], paths: paths).contains(where: { $0.id == backup.id }) else { throw AppFailure("未找到删除前的容器备份 / Removal container backup unavailable") }
        let container = GameContainer(appID: backup.appID, library: game.library, isWine: backup.isWine)
        try await GameContainers.restore(backup, to: container, paths: paths, relocating: true, requireIdle: requireIdle)
    }
    public static func restore(_ backup: GameSaveBackup, paths: AppPaths,
        requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle,
        checkUsage: @Sendable ([URL]) async throws -> Void = GameRemoval.requireUnused) async throws {
        try requireIdle()
        let state = try SaveManagerStore.load(paths: paths)
        guard state.backups.contains(where: { $0.id == backup.id && $0.source == backup.source && $0.directory == backup.directory && $0.appID == backup.appID }) else {
            throw AppFailure("存档备份记录已变化 / Save backup record changed")
        }
        let target = try destination(backup, paths: paths)
        _ = try Saves.verifyBackup(URL(fileURLWithPath: backup.directory))
        try requireIdle()
        try await checkUsage([target, installedGame(backup.appID, paths: paths).folder])
        let containers = GameContainers.all(paths).filter { $0.appID == backup.appID && GameRemoval.contains($0.prefix, target) }
        try await GameContainers.protectingRemoval(containers, paths: paths, requireIdle: requireIdle, backupReason: "before-restore") {
            let result = try Saves.restore(URL(fileURLWithPath: backup.directory), to: target, backupRoot: paths.data.appendingPathComponent("SaveBackups"))
            if let previous = result.previousBackup {
                try SaveManagerStore.recordBackup(.init(appID: backup.appID, source: target, directory: previous,
                    fileCount: try Saves.verifyBackup(previous).count, reason: "before-restore"), paths: paths)
            }
        }
    }
}
