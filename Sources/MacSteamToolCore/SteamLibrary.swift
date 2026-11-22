import Foundation

public enum SteamLibrary {
    public static func cachedDepotKeys(_ ids: Set<Int>, paths: AppPaths) throws -> [Int: String] {
        guard !ids.isEmpty else { return [:] }
        let file = paths.steam.appendingPathComponent("config/config.vdf")
        guard FileStore.fm.fileExists(atPath: file.path) else { return [:] }
        let config = try VDF.parse(FileStore.text(file))
        let depots = config.object("InstallConfigStore")?.object("Software")?
            .object("Valve")?.object("Steam")?.object("depots")
        var keys: [Int: String] = [:]
        for entry in depots?.entries ?? [] {
            guard let id = TextUtil.validID(entry.key), ids.contains(id),
                  let key = entry.children?.string("DecryptionKey")?.lowercased(), TextUtil.validKey(key) else { continue }
            if let previous = keys[id], previous != key {
                throw AppFailure("Steam 本机缓存存在冲突：Depot \(id) / Conflicting Steam cache entries")
            }
            keys[id] = key
        }
        return keys
    }

    public static func libraries(_ paths: AppPaths) -> [URL] { LocalInstallations.libraries(at: paths.steam) }
    private static func selectedPrefix(_ config: Data?, appID: Int, root: URL) -> URL? {
        switch SteamCompatibility.selectedTool(config, appID: appID) {
        case FreeRuntime.toolID: return FreeRuntime.prefix(in: root)
        case LocalWine.toolID: return root.appendingPathComponent(LocalWine.prefixDirectory).appendingPathComponent("pfx")
        default: return nil
        }
    }
    public static func installed(_ paths: AppPaths) -> [InstalledGame] {
        let config = try? FileStore.read(paths.steam.appendingPathComponent("config/config.vdf"))
        return LocalInstallations.installed(at: paths.steam).map { game in
            var result = game
            result.selectedPrefix = selectedPrefix(config, appID: game.id, root: game.library.appendingPathComponent("steamapps/compatdata/\(game.id)"))
            return result
        }
    }
    public static func prefixes(_ paths: AppPaths) -> [(id: Int, url: URL)] {
        let compatibility = try? FileStore.read(paths.steam.appendingPathComponent("config/config.vdf"))
        return libraries(paths).flatMap { library in
            FileStore.files(library.appendingPathComponent("steamapps/compatdata")).compactMap { root in
                guard let id = TextUtil.validID(root.lastPathComponent) else { return nil }
                let pfx = selectedPrefix(compatibility, appID: id, root: root) ?? root.appendingPathComponent("pfx")
                guard FileStore.fm.fileExists(atPath: pfx.path) else { return nil }
                return (id, pfx)
            }
        }
    }
    public static func games(_ paths: AppPaths, metadata: [Int: GameMetadata] = [:]) throws -> [Game] {
        let config = FileStore.fm.fileExists(atPath: paths.config.path) ? try MacSteamConfig.parse(FileStore.text(paths.config)) : MacSteamConfig()
        var result: [Int: Game] = [:]
        for id in config.topLevel {
            result[id] = Game(id: id, name: metadata[id]?.name ?? config.names[id] ?? "App \(id)", enabled: true,
                              dlcIDs: config.children(id), depotCount: config.keys[id]?.count ?? 0)
        }
        for dir in [paths.lua, paths.disabled] {
            for file in FileStore.files(dir) where file.pathExtension.lowercased() == "lua" {
                do {
                    let doc = try LuaDocument.parse(FileStore.text(file), suggestedID: TextUtil.validID(file.deletingPathExtension().lastPathComponent))
                    if result[doc.appID]?.luaURL != nil { result[doc.appID]?.warnings.append("启用与禁用文件夹有重复 Lua，请处理重复文件 / Duplicate Lua files in enabled and disabled folders; resolve the duplicates"); continue }
                    var game = result[doc.appID] ?? Game(id: doc.appID, name: "App \(doc.appID)")
                    game.luaURL = file; game.source = "Lua"; game.dlcIDs = doc.dlcIDs; game.depotCount = doc.depots.count
                    game.name = metadata[doc.appID]?.name ?? config.names[doc.appID] ?? (doc.name.isEmpty ? "App \(doc.appID)" : doc.name)
                    game.warnings += doc.warnings
                    if dir == paths.disabled && game.enabled { game.warnings.append("Lua 在禁用目录，但 macSteam 配置仍启用此游戏 / Lua is in the disabled folder but macSteam still enables this game") }
                    result[doc.appID] = game
                } catch {
                    if let id = TextUtil.validID(file.deletingPathExtension().lastPathComponent) {
                        result[id] = Game(id: id, name: "App \(id)", luaURL: file, enabled: config.apps.contains(id), source: "Lua", warnings: [error.localizedDescription])
                    } else { throw AppFailure("\(file.lastPathComponent)：\(error.localizedDescription)") }
                }
            }
        }
        for installed in installed(paths) {
            if result[installed.id] != nil { result[installed.id]?.installed = installed }
            else { result[installed.id] = Game(id: installed.id, name: metadata[installed.id]?.name ?? installed.name, installed: installed, source: "Steam") }
        }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct ImportPlan: Sendable {
    public var files: [ImportFile]
    public var documents: [LuaDocument]
    public var warnings: [String]
    public var replacing: [String]
}

public final class LibraryService {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }
    public func configSnapshot() throws -> (MacSteamConfig, String) {
        guard FileStore.fm.fileExists(atPath: paths.config.path) else { return (MacSteamConfig(), "missing") }
        let data = try FileStore.read(paths.config)
        guard let text = String(data: data, encoding: .utf8) else { throw AppFailure("macSteam 配置不是 UTF-8 / macSteam configuration is not UTF-8") }
        return (try MacSteamConfig.parse(text), FileStore.hash(data))
    }
    public func plan(_ files: [ImportFile]) throws -> ImportPlan {
        var documents: [LuaDocument] = []; var replacing: [String] = []; var warnings: [String] = []
        var ids = Set<Int>(); var destinations = Set<String>()
        for file in files {
            let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
            let target: URL
            if ext == "lua" {
                guard let text = String(data: file.data, encoding: .utf8) else { throw AppFailure("Lua 编码必须为 UTF-8 / Lua must use UTF-8 encoding") }
                let suggested = TextUtil.validID(URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent)
                let doc = try LuaDocument.parse(text, suggestedID: suggested)
                guard ids.insert(doc.appID).inserted else { throw AppFailure("重复的游戏 Lua / Duplicate game Lua file：\(doc.appID)") }
                documents.append(doc); warnings += doc.warnings
                target = paths.lua.appendingPathComponent("\(doc.appID).lua")
            } else if ext == "manifest" {
                guard let match = TextUtil.matches(#"^(\d+)_(\d+)\.manifest$"#, file.name).first,
                      let depot = TextUtil.validID(match[1]) else { throw AppFailure("无效的 depot manifest 文件名 / Invalid depot manifest filename：\(file.name)") }
                try SteamManifest.validate(file.data, depot: depot, manifest: match[2])
                target = paths.depotCache.appendingPathComponent(file.name)
            } else if ext == "bin" {
                guard !TextUtil.matches(#"^UserGameStatsSchema_\d+\.bin$"#, file.name).isEmpty else { throw AppFailure("只支持 UserGameStatsSchema_<AppID>.bin 格式 / Only UserGameStatsSchema_<AppID>.bin is supported") }
                target = paths.steam.appendingPathComponent("appcache/stats/\(file.name)")
            } else { throw AppFailure("不支持的文件 / Unsupported file：\(file.name)") }
            guard destinations.insert(target.path).inserted else { throw AppFailure("重复的目标文件 / Duplicate destination file") }
            if FileStore.fm.fileExists(atPath: target.path) { replacing.append(target.lastPathComponent) }
        }
        return ImportPlan(files: files, documents: documents, warnings: Array(Set(warnings)).sorted(), replacing: replacing)
    }
    public func perform(_ plan: ImportPlan) throws {
        var (config, hash) = try configSnapshot()
        var changes: [(URL, Data?)] = []
        for doc in plan.documents {
            try config.merge(doc)
            changes.append((paths.lua.appendingPathComponent("\(doc.appID).lua"), Data(doc.raw.utf8)))
            let disabled = paths.disabled.appendingPathComponent("\(doc.appID).lua")
            if FileStore.fm.fileExists(atPath: disabled.path) { changes.append((disabled, nil)) }
        }
        for file in plan.files {
            if file.name.hasSuffix(".manifest") { changes.append((paths.depotCache.appendingPathComponent(file.name), file.data)) }
            if file.name.hasSuffix(".bin") { changes.append((paths.steam.appendingPathComponent("appcache/stats/\(file.name)"), file.data)) }
        }
        if !plan.documents.isEmpty { changes.append((paths.config, Data(config.serialized().utf8))) }
        try applyLibraryChanges(changes, config: config, hash: hash, apps: plan.documents.map(\.appID), reason: "导入 \(plan.documents.count) 个游戏 / \(plan.files.count) 个文件")
    }
    public func setEnabled(_ game: Game, enabled: Bool) throws {
        var (config, hash) = try configSnapshot()
        var changes: [(URL, Data?)] = []
        let content = try game.luaURL.map { try FileStore.text($0) } ?? config.lua(for: game.id)
        let doc = try LuaDocument.parse(content, suggestedID: game.id)
        if enabled { try config.merge(doc, name: game.name) } else { config.remove(game.id) }
        let target = (enabled ? paths.lua : paths.disabled).appendingPathComponent("\(game.id).lua")
        let opposite = (enabled ? paths.disabled : paths.lua).appendingPathComponent("\(game.id).lua")
        changes.append((target, Data(content.utf8)))
        if FileStore.fm.fileExists(atPath: opposite.path) { changes.append((opposite, nil)) }
        changes.append((paths.config, Data(config.serialized().utf8)))
        try applyLibraryChanges(changes, config: config, hash: hash, apps: enabled ? [game.id] : [], removing: enabled ? [] : [game.id], reason: "\(enabled ? "启用" : "禁用") \(game.name)")
    }
    public func remove(_ game: Game) throws {
        try SaveGameMetadataStore.remember(paths: paths, games: [game])
        var (config, hash) = try configSnapshot(); config.remove(game.id)
        var changes: [(URL, Data?)] = [(paths.config, Data(config.serialized().utf8))]
        for file in [paths.lua.appendingPathComponent("\(game.id).lua"), paths.disabled.appendingPathComponent("\(game.id).lua")] where FileStore.fm.fileExists(atPath: file.path) { changes.append((file, nil)) }
        try applyLibraryChanges(changes, config: config, hash: hash, apps: [], removing: [game.id], restoreScope: [game.id], reason: "移除 \(game.name)")
    }
    public enum BatchAction { case enable, disable, remove }
    public func batch(_ games: [Game], action: BatchAction) throws {
        guard !games.isEmpty, Set(games.map(\.id)).count == games.count, games.allSatisfy({ $0.source != "Steam" }) else { throw AppFailure("请选择受管游戏 / Select managed games") }
        if action == .remove { try SaveGameMetadataStore.remember(paths: paths, games: games) }
        var (config, hash) = try configSnapshot()
        var changes: [(URL, Data?)] = [], enabled: [Int] = [], removed: [Int] = []
        for game in games {
            let active = paths.lua.appendingPathComponent("\(game.id).lua"), disabled = paths.disabled.appendingPathComponent("\(game.id).lua")
            if action == .remove {
                config.remove(game.id); removed.append(game.id)
                for file in [active, disabled] where FileStore.fm.fileExists(atPath: file.path) { changes.append((file, nil)) }
            } else {
                let content = try game.luaURL.map { try FileStore.text($0) } ?? config.lua(for: game.id)
                let doc = try LuaDocument.parse(content, suggestedID: game.id)
                guard doc.appID == game.id else { throw AppFailure("Lua AppID 不匹配 / Lua AppID mismatch") }
                if action == .enable { try config.merge(doc, name: game.name); enabled.append(game.id) }
                else { config.remove(game.id); removed.append(game.id) }
                changes.append((action == .enable ? active : disabled, Data(content.utf8)))
                let opposite = action == .enable ? disabled : active
                if FileStore.fm.fileExists(atPath: opposite.path) { changes.append((opposite, nil)) }
            }
        }
        changes.append((paths.config, Data(config.serialized().utf8)))
        try applyLibraryChanges(changes, config: config, hash: hash, apps: enabled, removing: removed, restoreScope: action == .remove ? games.map(\.id) : nil, reason: "批量管理 \(games.count) 个游戏")
    }
    public func export(_ games: [Game], to url: URL) throws {
        let (config, _) = try configSnapshot(); var files: [ImportFile] = []; var names = Set<String>()
        for game in games {
            let lua = try game.luaURL.map { try FileStore.text($0) } ?? config.lua(for: game.id)
            files.append(ImportFile(name: "\(game.id).lua", data: Data(lua.utf8)))
            let doc = try LuaDocument.parse(lua, suggestedID: game.id)
            var refs = doc.pins.map { "\($0.depot)_\($0.manifest).manifest" }
            refs += (game.installed?.depots ?? [:]).map { "\($0.key)_\($0.value).manifest" }
            for name in refs where names.insert(name).inserted {
                let file = paths.depotCache.appendingPathComponent(name)
                if FileStore.fm.fileExists(atPath: file.path) { files.append(ImportFile(name: name, data: try FileStore.read(file))) }
            }
            let bin = "UserGameStatsSchema_\(game.id).bin"; let file = paths.steam.appendingPathComponent("appcache/stats/\(bin)")
            if FileStore.fm.fileExists(atPath: file.path) { files.append(ImportFile(name: bin, data: try FileStore.read(file))) }
        }
        try ArchiveIO.export(files, to: url)
    }
    public func saveLua(_ text: String, game: Game) throws {
        let doc = try LuaDocument.parse(text, suggestedID: game.id)
        var (config, hash) = try configSnapshot()
        if game.enabled { config.remove(game.id); try config.merge(doc, name: game.name) }
        let target = game.luaURL ?? (game.enabled ? paths.lua : paths.disabled).appendingPathComponent("\(game.id).lua")
        try applyLibraryChanges([(target, Data(text.utf8)), (paths.config, Data(config.serialized().utf8))], config: config, hash: hash, apps: game.enabled ? [game.id] : [], removing: game.enabled ? [] : [game.id], reason: "编辑 \(game.name)")
    }
    private func applyLibraryChanges(_ changes: [(URL, Data?)], config: MacSteamConfig, hash: String, apps: [Int], removing: [Int] = [], restoreScope: [Int]? = nil, additionalExpectations: [URL: String] = [:], reason: String) throws {
        var changes = changes
        var expectations = additionalExpectations
        expectations[paths.config] = hash
        if let pending = try AutomaticCompatibility.queueChange(paths: paths, config: config, apps: apps, removing: removing) {
            changes.append((pending.url, pending.data)); expectations[pending.url] = pending.expected
        }
        if let pending = try AutomaticAchievements.queueChange(paths: paths, config: config, apps: apps, removing: removing) {
            changes.append((pending.url, pending.data)); expectations[pending.url] = pending.expected
        }
        try FileTransaction(backupRoot: paths.backups).apply(changes, reason: reason, expectations: expectations, libraryAppIDs: restoreScope)
    }
    /// Older removal records did not store IDs; recover them only from exact
    /// managed Lua paths. Config-only legacy records cannot be scoped safely.
    public func restoreGameIDs(_ record: BackupRecord) throws -> [Int]? {
        if let ids = record.libraryAppIDs {
            guard !ids.isEmpty, Set(ids).count == ids.count,
                  ids.allSatisfy({ TextUtil.validID(String($0)) != nil }) else { throw AppFailure("备份游戏范围无效 / Invalid backup game scope") }
            return ids.sorted()
        }
        guard record.reason.hasPrefix("移除 ") || record.reason.hasPrefix("批量管理 ") else { return nil }
        let ids = Set(record.files.compactMap { file -> Int? in
            let url = URL(fileURLWithPath: file.original).standardizedFileURL
            guard [paths.lua.standardizedFileURL, paths.disabled.standardizedFileURL].contains(url.deletingLastPathComponent()),
                  url.pathExtension == "lua" else { return nil }
            return TextUtil.validID(url.deletingPathExtension().lastPathComponent)
        })
        guard !ids.isEmpty else { throw AppFailure("旧备份缺少游戏范围，无法安全地单独恢复 / Legacy backup has no game scope; cannot restore without affecting other games") }
        return ids.sorted()
    }

    public func restoreBackup(_ record: BackupRecord, appIDs: [Int]? = nil) throws {
        let journal = FileTransaction(backupRoot: paths.backups)
        let roots = [paths.steam, paths.macSteam, paths.lua, paths.data]
        guard let available = try restoreGameIDs(record) else {
            guard appIDs == nil else { throw AppFailure("此备份不支持按游戏恢复 / This backup does not support per-game restore") }
            let changes: [(URL, Data?)] = try journal.verifiedChanges(record, allowedRoots: roots).map { url, data in
                if url == StatisticsConfiguration.url(paths).standardizedFileURL, let data {
                    return (url, try StatisticsConfiguration.disablingLegacySaveRedirection(in: data))
                }
                return (url, data)
            }
            try journal.apply(changes, reason: "还原 \(record.reason)")
            return
        }
        let ids = appIDs ?? available
        guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: available) else { throw AppFailure("所选游戏不在备份范围内 / Selected games are outside the backup scope") }
        let saved = try journal.verifiedChanges(record, allowedRoots: roots)
        guard let configEntry = saved.first(where: { $0.0 == paths.config.standardizedFileURL }) else {
            throw AppFailure("备份缺少入库配置 / Backup has no library configuration")
        }
        let old = try configEntry.1.map { bytes -> MacSteamConfig in
            guard let text = String(data: bytes, encoding: .utf8) else { throw AppFailure("备份配置编码无效 / Invalid backup configuration encoding") }
            return try MacSteamConfig.parse(text)
        } ?? MacSteamConfig()
        var (current, hash) = try configSnapshot()
        let selected = Set(ids)
        // Include only descendants of the selected games, never another game's
        // DLC or a selected ID that has since become owned by another game.
        func family(_ config: MacSteamConfig) -> Set<Int> {
            var result = selected
            while true {
                let next = result.union(config.parents.filter { result.contains($0.value) }.keys)
                if next == result { return result }
                result = next
            }
        }
        let previousFamily = family(old), currentFamily = family(current)
        guard previousFamily.intersection(current.apps).isSubset(of: currentFamily) else {
            throw AppFailure("备份内容与其他游戏冲突，未恢复 / Backup content conflicts with another game; nothing restored")
        }
        for id in previousFamily.union(currentFamily) {
            if let parent = old.parents[id], !previousFamily.contains(parent) { throw AppFailure("备份中的 DLC 归属冲突 / Backup DLC ownership conflict") }
            if let parent = current.parents[id], !currentFamily.contains(parent) { throw AppFailure("该内容现属于其他游戏，未恢复 / Content now belongs to another game; nothing restored") }
        }
        for id in ids { current.remove(id) }
        for id in old.apps where previousFamily.contains(id) {
            if !current.apps.contains(id) { current.apps.append(id) }
            current.parents[id] = old.parents[id]
            current.names[id] = old.names[id]
            current.keys[id] = old.keys[id]
            current.manifestPins[id] = old.manifestPins[id]
            current.accessTokens[id] = old.accessTokens[id]
        }
        try current.validate()
        var changes: [(URL, Data?)] = [(paths.config, Data(current.serialized().utf8))]
        var expectations: [URL: String] = [:]
        for id in ids {
            for directory in [paths.lua, paths.disabled] {
                let url = directory.appendingPathComponent("\(id).lua").standardizedFileURL
                let data = saved.first(where: { $0.0 == url })?.1
                expectations[url] = FileStore.fm.fileExists(atPath: url.path) ? FileStore.hash(try FileStore.read(url)) : "missing"
                changes.append((url, data))
            }
        }
        // Requeue only restored games against today's state. Historical queue
        // snapshots must not replace other games' jobs or manual choices.
        let enabled = ids.filter { current.topLevel.contains($0) }
        try applyLibraryChanges(changes, config: current, hash: hash, apps: enabled,
            removing: ids.filter { !enabled.contains($0) }, restoreScope: ids,
            additionalExpectations: expectations, reason: "还原 \(record.reason)")
    }

    public func synchronizeManifestPins() throws {
        var (config, hash) = try configSnapshot()
        for file in FileStore.files(paths.lua) where file.pathExtension.lowercased() == "lua" {
            let document = try LuaDocument.parse(FileStore.text(file), suggestedID: TextUtil.validID(file.deletingPathExtension().lastPathComponent))
            guard config.apps.contains(document.appID) else { continue }
            // Reuse validation without changing app membership or depot keys.
            var checked = config
            try checked.merge(document)
            config.manifestPins[document.appID] = checked.manifestPins[document.appID]
            for id in [document.appID] + document.dlcIDs where config.apps.contains(id) { config.accessTokens[id] = checked.accessTokens[id] }
        }
        try config.validate()
        let data = Data(config.serialized().utf8)
        if data == (try? FileStore.read(paths.config)) { return }
        try FileTransaction(backupRoot: paths.backups).apply([(paths.config, data)], reason: "同步已有 Lua 锁定与访问令牌", expectations: [paths.config: hash])
    }
}
