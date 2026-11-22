import Foundation

public struct GameRemovalPlan: Sendable {
    public let game: Game
    public let targets: [URL]
    public let saves: [SaveLocation]
    public let containers: [GameContainer]
    public let manifestHashes: [URL: String]
}

public enum GameRemoval {
    public static func requireUnused(_ targets: [URL]) async throws {
        for target in targets where (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let (code, output) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "+D", target.path])
            guard code == 1, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure("目录仍在使用或无法核实，请关闭游戏和相关工具 / Folder is in use or could not be checked: \(target.path)")
            }
        }
    }
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.path, b = child.standardizedFileURL.path
        return a == b || b.hasPrefix(a + "/")
    }
    static func noLinks(_ url: URL) throws {
        var part = url.path
        while part != "/" && !part.isEmpty {
            if let attributes = try? FileStore.fm.attributesOfItem(atPath: part), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // macOS exposes these system-owned aliases even for Foundation
                // URLs initially resolved through /private. No user links allowed.
                let systemAlias = ["/var": "/private/var", "/tmp": "/private/tmp"][part]
                let link = try FileStore.fm.destinationOfSymbolicLink(atPath: part)
                guard let systemAlias, link == systemAlias || "/" + link == systemAlias else {
                    throw AppFailure("路径包含符号链接，未执行删除或恢复 / Path contains a symbolic link: \(url.path)")
                }
            }
            part = (part as NSString).deletingLastPathComponent
        }
    }
    public static func plan(game: Game, paths: AppPaths) throws -> GameRemovalPlan {
        guard game.source != "Steam", TextUtil.validID(String(game.id)) != nil else { throw AppFailure("请选择受管游戏 / Select a managed game") }
        let installed = SteamLibrary.installed(paths)
        let containers = GameContainers.all(paths).filter { $0.appID == game.id }
        let state = try SaveManagerStore.load(paths: paths)
        var saves = (Saves.locations(paths) + SaveManagement.customLocations(state)).filter { $0.appID == game.id }
        // The standard scanner follows the selected backend only. Include both.
        for container in containers {
            try GameContainers.validate(container, paths: paths)
            for user in FileStore.files(container.prefix.appendingPathComponent("drive_c/users")) where user.lastPathComponent != "Public" {
                if (try? user.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                for suffix in ["Documents", "Saved Games", "AppData/Local", "AppData/LocalLow", "AppData/Roaming"] {
                    let folder = user.appendingPathComponent(suffix)
                    if FileStore.fm.fileExists(atPath: folder.path), (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                        saves.append(SaveLocation(appID: game.id, kind: "Container", url: folder))
                    }
                }
            }
        }
        var seen = Set<String>()
        saves = saves.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        let otherSaves = (Saves.locations(paths) + SaveManagement.customLocations(state)).filter { $0.appID != game.id }
        let home = paths.data.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let protected = [home, FileManager.default.homeDirectoryForCurrentUser, paths.data, paths.steam, paths.macSteam, paths.lua, paths.notProton] +
            ["/Applications", "/System", "/Library", "/Users", "/Volumes", "/private", "/usr", "/bin", "/sbin"].map { URL(fileURLWithPath: $0) } +
            ["Documents", "Desktop", "Downloads", "Library"].flatMap { [home.appendingPathComponent($0), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0)] } +
            SteamLibrary.libraries(paths).flatMap { [$0, $0.appendingPathComponent("steamapps"), $0.appendingPathComponent("steamapps/common"), $0.appendingPathComponent("steamapps/compatdata")] }
        for save in saves {
            try noLinks(save.url)
            guard !protected.contains(where: { contains(save.url, $0) }),
                  !contains(paths.data, save.url),
                  !installed.contains(where: { $0.id != game.id && (contains(save.url, $0.folder) || contains($0.folder, save.url)) }),
                  !GameContainers.all(paths).contains(where: { $0.appID != game.id && (contains(save.url, $0.root) || contains($0.root, save.url)) }),
                  !otherSaves.contains(where: { contains(save.url, $0.url) || contains($0.url, save.url) }) else {
                throw AppFailure("存档目录范围过大或与其他游戏共用，请先设置独立目录 / Save folder is too broad or shared: \(save.url.path)")
            }
        }
        var targets = saves.map(\.url), hashes: [URL: String] = [:]
        for library in SteamLibrary.libraries(paths) {
            let manifest = library.appendingPathComponent("steamapps/appmanifest_\(game.id).acf")
            if FileStore.fm.fileExists(atPath: manifest.path) {
                guard let item = installed.first(where: { $0.id == game.id && $0.library == library }) else { throw AppFailure("安装清单无效，未删除 / Invalid install manifest") }
                guard item.folder.standardizedFileURL.deletingLastPathComponent() == library.appendingPathComponent("steamapps/common").standardizedFileURL else {
                    throw AppFailure("游戏安装目录范围无效 / Invalid game installation directory")
                }
                guard !installed.contains(where: { $0.id != game.id && (contains(item.folder, $0.folder) || contains($0.folder, item.folder)) }) else { throw AppFailure("游戏安装目录与其他游戏共用，未删除 / Shared game install folder") }
                targets += [item.folder, manifest]
                hashes[manifest] = FileStore.hash(try FileStore.read(manifest))
            }
            targets.append(library.appendingPathComponent("steamapps/compatdata/\(game.id)"))
            targets.append(library.appendingPathComponent("steamapps/downloading/\(game.id)"))
        }
        targets = Array(Set(targets.map(\.standardizedFileURL))).filter { FileStore.fm.fileExists(atPath: $0.path) }
        for target in targets {
            try noLinks(target)
            guard !contains(target, paths.data) else { throw AppFailure("删除目标包含备份目录 / Removal target contains backup storage") }
        }
        targets = targets.filter { candidate in !targets.contains { $0 != candidate && contains($0, candidate) } }.sorted { $0.path < $1.path }
        return .init(game: game, targets: targets, saves: saves, containers: containers, manifestHashes: hashes)
    }
    /// Back up all saves before moving any live directory. Stage on the same
    /// volume, roll back if config removal fails, then move staged data to Trash.
    public static func perform(_ preview: GameRemovalPlan, paths: AppPaths,
        requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle,
        checkUsage: @Sendable ([URL]) async throws -> Void = GameRemoval.requireUnused,
        retire: (URL) throws -> Void = { try FileStore.fm.trashItem(at: $0, resultingItemURL: nil) }) async throws -> [URL] {
        try requireIdle()
        let fresh = try plan(game: preview.game, paths: paths)
        guard fresh.targets == preview.targets, fresh.manifestHashes == preview.manifestHashes,
              Set(fresh.saves.map(\.id)) == Set(preview.saves.map(\.id)), Set(fresh.containers) == Set(preview.containers) else {
            throw AppFailure("游戏文件已变化，请重新打开删除预览 / Game files changed; reopen removal preview")
        }
        var retained: [URL] = []
        try await checkUsage(fresh.targets)
        try await GameContainers.protectingRemoval(fresh.containers, paths: paths, requireIdle: requireIdle) {
            let backupRoot = paths.data.appendingPathComponent("SaveBackups/removal-\(fresh.game.id)-\(UUID().uuidString)")
            for (index, save) in fresh.saves.enumerated() {
                let destination = backupRoot.appendingPathComponent(String(index))
                let count = try Saves.backup(save.url, to: destination)
                _ = try Saves.verifyBackup(destination)
                try SaveManagerStore.recordBackup(.init(appID: save.appID, source: save.url, directory: destination, fileCount: count, reason: "before-uninstall"), paths: paths)
            }
            try requireIdle()
            for (manifest, hash) in fresh.manifestHashes {
                guard FileStore.hash(try FileStore.read(manifest)) == hash else { throw AppFailure("安装清单已变化，未删除 / Install manifest changed; nothing deleted") }
            }
            var staged: [(original: URL, temporary: URL)] = []
            do {
                for target in fresh.targets {
                    try noLinks(target); try requireIdle()
                    let temporary = target.deletingLastPathComponent().appendingPathComponent(".fluent-removed-\(UUID().uuidString)-\(target.lastPathComponent)")
                    try FileStore.fm.moveItem(at: target, to: temporary)
                    staged.append((target, temporary))
                }
                try LibraryService(paths: paths).remove(fresh.game)
            } catch {
                var failures: [String] = []
                for item in staged.reversed() {
                    do { try FileStore.fm.moveItem(at: item.temporary, to: item.original) }
                    catch { failures.append(item.temporary.path) }
                }
                if !failures.isEmpty { throw AppFailure("删除失败，部分文件保留在 / Removal failed; retained files: \(failures.joined(separator: ", "))") }
                throw error
            }
            for item in staged {
                do { try retire(item.temporary) }
                catch { retained.append(item.temporary) }
            }
        }
        return retained
    }
}
