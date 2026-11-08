import Foundation

public struct GameSaveOptions: Codable, Equatable, Sendable {
    public var backupDirectory = ""
    public var customFolders: [String] = []
    public init() {}
}
public struct GameSaveBackup: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var appID: Int
    public var created = Date()
    public var source: String
    public var directory: String
    public var fileCount: Int
    public var reason: String
    public init(appID: Int, source: URL, directory: URL, fileCount: Int, reason: String) {
        self.appID = appID; self.source = source.path; self.directory = directory.path
        self.fileCount = fileCount; self.reason = reason
    }
}
public struct SaveManagerState: Codable, Sendable {
    public var version = 1
    public var games: [String: GameSaveOptions] = [:]
    public var backups: [GameSaveBackup] = []
    public init() {}
    public func options(for appID: Int) -> GameSaveOptions { games[String(appID)] ?? .init() }
    public func backups(for appID: Int) -> [GameSaveBackup] { backups.filter { $0.appID == appID }.sorted { $0.created > $1.created } }
}

public struct ManagedSaveGame: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let locations: [SaveLocation]
    public let backupCount: Int
    public let installed: Bool
}
public enum SaveManagement {
    public static func catalog(games: [Game], locations: [SaveLocation], state: SaveManagerState) -> [ManagedSaveGame] {
        var names: [Int: Game] = [:]
        for game in games { names[game.id] = game }
        var folders: [Int: [SaveLocation]] = [:], seen: [Int: Set<String>] = [:]
        for location in locations where seen[location.appID, default: []].insert(location.url.standardizedFileURL.path).inserted {
            folders[location.appID, default: []].append(location)
        }
        let backupCounts = state.backups.reduce(into: [Int: Int]()) { $0[$1.appID, default: 0] += 1 }
        let ids = Set(games.map(\.id) + locations.map(\.appID) + state.backups.map(\.appID) + state.games.keys.compactMap(TextUtil.validID))
        return ids.filter { TextUtil.validID(String($0)) != nil }.map { id in
            return ManagedSaveGame(id: id, name: names[id]?.name ?? "App \(id)", locations: folders[id] ?? [],
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
    public static func cloudSelection(_ config: CloudConfiguration, appID: Int, paths: AppPaths) throws -> Bool {
        var active = config; active.enabled = true
        return try active.selectedApps(paths: paths).contains(appID)
    }
    public static func settingCloudSelection(_ selected: Bool, appID: Int, config: CloudConfiguration, paths: AppPaths) throws -> CloudConfiguration {
        guard TextUtil.validID(String(appID)) != nil else { throw AppFailure("无效 AppID / Invalid AppID") }
        var result = config
        if config.automaticApps {
            if selected {
                let mac = try MacSteamConfig.parse(FileStore.text(paths.config))
                guard mac.apps.contains(appID), mac.parents[appID] == nil else { throw AppFailure("自动模式只接管 macSteam 已启用的主游戏 / Automatic mode only manages enabled macSteam base games") }
            }
            var excluded = Set(try CloudConfiguration.parseIDs(config.excludedApps))
            if selected { excluded.remove(appID) } else { excluded.insert(appID) }
            result.excludedApps = excluded.sorted().map(String.init).joined(separator: ", ")
        } else {
            var ids = Set(try CloudConfiguration.parseIDs(config.apps))
            if selected { ids.insert(appID) } else { ids.remove(appID) }
            guard !config.enabled || !ids.isEmpty else { throw AppFailure("这是最后一款接管游戏；请在云服务设置中关闭全局接管 / This is the last managed game; disable global redirection in cloud settings") }
            result.apps = ids.sorted().map(String.init).joined(separator: ", ")
        }
        return result
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
