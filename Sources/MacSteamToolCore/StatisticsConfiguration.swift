import Foundation

/// Statistics share a configuration file with older versions of the Steam extension.
public struct StatisticsConfiguration: Equatable, Sendable {
    public var statsApps = ""
    public var syncAchievements = false
    public var syncPlaytime = false
    private var source: Data?
    public init() {}

    static func url(_ paths: AppPaths) -> URL { paths.data.appendingPathComponent("CloudRedirect/config.json") }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure("统计配置损坏 / Invalid statistics configuration")
        }
        return json
    }

    public static func load(paths: AppPaths) throws -> Self {
        var value = Self()
        let file = url(paths)
        guard FileStore.fm.fileExists(atPath: file.path) else { return value }
        let data = try FileStore.read(file)
        let json = try object(data)
        value.source = data
        value.statsApps = (json["stats_apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
        value.syncAchievements = json["sync_achievements"] as? Bool ?? false
        value.syncPlaytime = json["sync_playtime"] as? Bool ?? false
        return value
    }

    var appIDs: [Int] {
        get throws {
            let parts = statsApps.split { $0.isWhitespace || $0 == "," || $0 == "，" }
            let ids = parts.compactMap { TextUtil.validID(String($0)) }
            guard ids.count == parts.count, ids.count <= 4096 else {
                throw AppFailure("统计 AppID 列表无效 / Invalid statistics AppID list")
            }
            return Array(Set(ids)).sorted()
        }
    }

    public func save(paths: AppPaths) throws {
        let ids = try appIDs
        guard !(syncAchievements || syncPlaytime) || !ids.isEmpty else {
            throw AppFailure("请选择需要记录统计的 AppID / Select AppIDs to track")
        }
        var json = try source.map(Self.object) ?? [:]
        json["enabled"] = false
        json["stats_apps"] = ids
        json["sync_achievements"] = syncAchievements
        json["sync_playtime"] = syncPlaytime
        json["stats_sync_enabled"] = syncAchievements || syncPlaytime
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let file = Self.url(paths)
        try FileTransaction(backupRoot: paths.backups).apply([(file, data)], reason: "更新游戏统计设置",
            expectations: [file: source.map(FileStore.hash) ?? "missing"])
    }

    static func disablingLegacySaveRedirection(in data: Data) throws -> Data {
        var json = try object(data)
        guard json["enabled"] as? Bool == true else { return data }
        json["enabled"] = false
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Older installed extensions also read this flag. Leave the save folders and credentials in place.
    @discardableResult public static func retireLegacySaveRedirection(paths: AppPaths) throws -> Bool {
        let file = url(paths)
        guard FileStore.fm.fileExists(atPath: file.path) else { return false }
        let old = try FileStore.read(file)
        let new = try disablingLegacySaveRedirection(in: old)
        guard new != old else { return false }
        try FileTransaction(backupRoot: paths.backups).apply([(file, new)], reason: "停用旧版存档接管",
            expectations: [file: FileStore.hash(old)])
        return true
    }

    static func legacySaveFolder(paths: AppPaths) throws -> String? {
        let file = url(paths)
        guard FileStore.fm.fileExists(atPath: file.path) else { return nil }
        let json = try object(FileStore.read(file))
        return (json["token_paths"] as? [String: String])?["folder"]
            ?? (json["provider"] as? String == "folder" ? json["token_path"] as? String : nil)
    }
}
