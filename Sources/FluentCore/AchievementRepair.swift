import Foundation

/// Schema bootstrap used by upstream OpenSteamTool. The public user's data is
/// requested in an isolated read-only session, and only Steam's schema cache is
/// retained. The compatibility store continues to belong to the signed-in user.
public enum AchievementRepair {
    public static func sourceID(_ data: Data) throws -> UInt64 {
        guard data.count <= 128, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let id = UInt64(text),
              id > 76561197960265728, id < 76561202255233024 else { throw AppFailure("公开成就定义来源无效 / Invalid public achievement schema source") }
        return id
    }
    public static func prepare(appID: Int, paths: AppPaths, worker: URL) async throws {
        try await fetchSchema(appID: appID, paths: paths, worker: worker)
        try enable(appID: appID, paths: paths)
    }
    /// Fetch definitions without changing the active cloud/statistics configuration.
    public static func fetchSchema(appID: Int, paths: AppPaths, worker: URL) async throws {
        try checkManaged(appID, paths: paths)
        let data = try await HTTP.get(HTTP.url("https://stats.luastools.xyz/\(appID)"), limit: 128)
        var request = AchievementRequest(appID: appID, library: paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib").path)
        request.operation = "schema"; request.schemaSourceSteamID = try sourceID(data)
        let result = try await AchievementWorker.run(request, executable: worker)
        guard result.schemaLoaded == true, result.achievements.isEmpty, !result.stored else { throw AppFailure("成就定义初始化失败 / Achievement schema bootstrap failed") }
        guard schemaAvailable(appID: appID, paths: paths) else { throw AppFailure("Steam 未缓存有效成就定义 / Steam did not cache valid achievement definitions") }
    }
    public static func schemaAvailable(appID: Int, paths: AppPaths) -> Bool {
        let url = paths.steam.appendingPathComponent("appcache/stats/UserGameStatsSchema_\(appID).bin")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
              let blob = try? FileStore.read(url) else { return false }
        return blob.starts(with: Data([0] + Array(String(appID).utf8) + [0])) && blob.last == 8
    }
    static func checkManaged(_ appID: Int, paths: AppPaths) throws {
        guard TextUtil.validID(String(appID)) != nil else { throw AppFailure("Invalid AppID") }
        let config = try MacSteamConfig.parse(FileStore.text(paths.config))
        guard config.apps.contains(appID), config.parents[appID] == nil else { throw AppFailure("兼容成就只适用于已启用的主游戏 / Compatibility achievements require an enabled main game") }
    }
    /// Preserve every save/provider/playtime setting. Persist only the explicit
    /// selected app's achievement scope, with an ordinary restorable backup.
    public static func enable(appID: Int, paths: AppPaths, validate: () throws -> Void = {}) throws {
        try validate()
        try checkManaged(appID, paths: paths)
        let schema = paths.steam.appendingPathComponent("appcache/stats/UserGameStatsSchema_\(appID).bin")
        let blob = try FileStore.read(schema)
        guard blob.starts(with: Data(([0] + Array(String(appID).utf8) + [0]))), blob.count <= 16 * 1024 * 1024 else { throw AppFailure("Steam 未缓存此游戏的有效成就定义 / Steam did not cache a valid schema for this app") }
        let url = paths.data.appendingPathComponent("CloudRedirect/config.json")
        let old = FileStore.fm.fileExists(atPath: url.path) ? try FileStore.read(url) : nil
        var json: [String: Any] = [:]
        if let old {
            guard let parsed = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { throw AppFailure("统计配置损坏 / Invalid statistics configuration") }
            json = parsed
        }
        guard json["stats_apps"] == nil || json["stats_apps"] is [Int] else { throw AppFailure("Invalid statistics app list") }
        var apps = Set(json["stats_apps"] as? [Int] ?? [])
        guard (json["sync_achievements"] as? Bool ?? false) || apps.subtracting([appID]).isEmpty else { throw AppFailure("现有统计列表还包含其他游戏，请先在成就页的统计设置中确认成就范围 / Confirm the achievement scope in statistics settings before enabling other listed games") }
        guard !(json["sync_playtime"] as? Bool ?? false) || apps.contains(appID) else { throw AppFailure("此游戏未包含在现有时长同步范围内，请在成就页的统计设置中单独选择 / Select this app in statistics settings before expanding an active playtime scope") }
        apps.insert(appID)
        json["stats_apps"] = apps.sorted(); json["sync_achievements"] = true; json["stats_sync_enabled"] = true
        let new = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        if let old, NSDictionary(dictionary: json).isEqual(to: (try JSONSerialization.jsonObject(with: old) as? [String: Any]) ?? [:]) { return }
        try FileTransaction(backupRoot: paths.backups).apply([(url, new)], reason: "初始化兼容成就 App \(appID)", expectations: [url: old.map(FileStore.hash) ?? "missing"]) {
            try validate()
            try checkManaged(appID, paths: paths)
            let current = FileStore.fm.fileExists(atPath: url.path) ? try FileStore.read(url) : nil
            guard current == old else { throw AppFailure("统计配置已变化，请重试 / Statistics configuration changed; retry") }
        }
    }
    public static func enabled(appID: Int, paths: AppPaths) -> Bool {
        guard let c = try? StatisticsConfiguration.load(paths: paths) else { return false }
        return c.syncAchievements && ((try? c.appIDs) ?? []).contains(appID)
    }
}
