import Foundation

public struct ManagedSaveGame: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let image: String?
    public let locations: [SaveLocation]
    public let backupCount: Int
    public let installed: Bool
}
public enum SaveManagement {
    public static func catalog(games: [Game], locations: [SaveLocation], state: SaveManagerState, metadata: [Int: SaveGameMetadata] = [:], language: String = "schinese") -> [ManagedSaveGame] {
        var names: [Int: Game] = [:]
        for game in games { names[game.id] = game }
        var folders: [Int: [SaveLocation]] = [:], seen: [Int: Set<String>] = [:]
        for location in locations where seen[location.appID, default: []].insert(location.url.standardizedFileURL.path).inserted {
            folders[location.appID, default: []].append(location)
        }
        let backupCounts = state.backups.reduce(into: [Int: Int]()) { $0[$1.appID, default: 0] += 1 }
        let ids = Set(games.map(\.id) + locations.map(\.appID) + state.backups.map(\.appID) + state.games.keys.compactMap(TextUtil.validID))
        return ids.filter { TextUtil.validID(String($0)) != nil }.map { id in
            let title = metadata[id]?.localizedNames[language] ?? SaveGameMetadata.title(names[id]?.name, id: id)
                ?? metadata[id]?.displayName(language: language) ?? "App \(id)"
            return ManagedSaveGame(id: id, name: title, image: metadata[id]?.image, locations: folders[id] ?? [],
                                   backupCount: backupCounts[id] ?? 0, installed: names[id]?.installed != nil)
        }.sorted { a, b in a.name == b.name ? a.id < b.id : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    public static func filtered(_ games: [ManagedSaveGame], query: String, onlyWithSaves: Bool) -> [ManagedSaveGame] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return games.filter { (!onlyWithSaves || !$0.locations.isEmpty || $0.backupCount > 0) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.id).contains(query)) }
    }
    public static func customLocations(_ state: SaveManagerState) -> [SaveLocation] {
        state.games.flatMap { key, options -> [SaveLocation] in
            guard let id = TextUtil.validID(key) else { return [] }
            return options.customFolders.compactMap { path in
                let url = URL(fileURLWithPath: path)
                guard isSpecificAbsoluteFolder(path), (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { return nil }
                return SaveLocation(appID: id, kind: "Custom", url: url)
            }
        }
    }
    static func isSpecificAbsoluteFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.split(separator: "/").isEmpty &&
        !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) &&
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

public enum SaveManagerStore {
    private static func url(_ paths: AppPaths) -> URL { paths.data.appendingPathComponent("SaveManager/state.json") }
    public static func load(paths: AppPaths) throws -> SaveManagerState {
        guard FileStore.fm.fileExists(atPath: url(paths).path) else { return .init() }
        let state = try FileStore.decode(SaveManagerState.self, at: url(paths))
        guard state.version == 1 else { throw AppFailure("不支持的存档管理配置版本 / Unsupported save manager state version") }
        return state
    }
    public static func saveOptions(_ options: GameSaveOptions, appID: Int, paths: AppPaths) throws {
        guard TextUtil.validID(String(appID)) != nil else { throw AppFailure("无效 AppID / Invalid AppID") }
        var clean = options
        clean.customFolders = Array(Set(options.customFolders)).sorted()
        for path in clean.customFolders + (clean.backupDirectory.isEmpty ? [] : [clean.backupDirectory]) {
            guard SaveManagement.isSpecificAbsoluteFolder(path) else { throw AppFailure("请选择具体的绝对目录路径，不可选择整个磁盘根目录 / Select a specific absolute folder, not the disk root") }
        }
        try update(paths: paths) { $0.games[String(appID)] = clean }
    }
    public static func recordBackup(_ backup: GameSaveBackup, paths: AppPaths) throws {
        guard TextUtil.validID(String(backup.appID)) != nil, backup.fileCount >= 0,
              backup.source.hasPrefix("/"), backup.directory.hasPrefix("/") else { throw AppFailure("无效备份记录 / Invalid backup record") }
        try update(paths: paths) { state in
            state.backups.removeAll { $0.directory == backup.directory }
            state.backups.append(backup)
        }
    }
    public static func remindAfterInstall(_ appIDs: [Int], enabled: Bool, paths: AppPaths) throws {
        try update(paths: paths) { state in
            var ids = Set(state.pendingReinstallRestores ?? [])
            if enabled { ids.formUnion(appIDs) } else { ids.subtract(appIDs) }
            state.pendingReinstallRestores = ids.sorted()
        }
    }
    private static func update(paths: AppPaths, _ mutation: (inout SaveManagerState) throws -> Void) throws {
        let file = url(paths)
        let old = FileStore.fm.fileExists(atPath: file.path) ? try FileStore.read(file) : nil
        var state = try old.map { try JSONDecoder().decode(SaveManagerState.self, from: $0) } ?? .init()
        guard state.version == 1 else { throw AppFailure("不支持的存档管理配置版本 / Unsupported save manager state version") }
        try mutation(&state)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileTransaction(backupRoot: paths.backups).apply([(file, try encoder.encode(state))], reason: "存档管理设置 / Save manager settings", expectations: [file: old.map(FileStore.hash) ?? "missing"])
    }
}
