import Foundation

public enum CacheMaintenance {
    /// Only disposable app cache. Tools, downloads, backups, credentials and Steam data are outside this list.
    public static let disposable = ["Metadata", "Covers", "Charts", "OfficialRuntimes", "OfflineStages", "Patches", "depotkeys.json"]
    public struct Summary: Sendable { public let bytes: Int64; public let entries: Int }
    private static func targets(paths: AppPaths) throws -> [URL] {
        let cache = paths.cache.standardizedFileURL
        guard cache.resolvingSymlinksInPath().standardizedFileURL == cache else { throw AppFailure("缓存目录不能是符号链接 / Cache directory cannot be a symbolic link") }
        let cloudFolder = try StatisticsConfiguration.legacySaveFolder(paths: paths) ?? ""
        let protected = [paths.steam, paths.macSteam, paths.notProton, paths.lua, paths.backups] + (cloudFolder.hasPrefix("/") ? [URL(fileURLWithPath: cloudFolder)] : [])
        return try disposable.compactMap { name in
            let target = cache.appendingPathComponent(name)
            guard FileStore.fm.fileExists(atPath: target.path) else { return nil }
            guard target.resolvingSymlinksInPath().standardizedFileURL == target.standardizedFileURL,
                  !protected.contains(where: { let path = $0.resolvingSymlinksInPath().standardizedFileURL.path; return path == target.path || path.hasPrefix(target.path + "/") || target.path.hasPrefix(path + "/") }) else { throw AppFailure("缓存路径与游戏或配置目录重叠，未清理 / Cache overlaps a game or configuration folder; nothing cleared") }
            return target
        }
    }
    public static func summary(paths: AppPaths) throws -> Summary {
        var bytes: Int64 = 0, entries = 0
        for root in try targets(paths: paths) {
            let items = [root] + ((FileStore.fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [])?.allObjects as? [URL]) ?? [])
            for file in items {
                let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if value.isSymbolicLink != true && value.isRegularFile == true { bytes += Int64(value.fileSize ?? 0); entries += 1 }
            }
        }
        return Summary(bytes: bytes, entries: entries)
    }
    public static func clear(paths: AppPaths) throws -> Summary {
        let before = try summary(paths: paths), items = try targets(paths: paths)
        guard !items.isEmpty else { return before }
        let quarantine = paths.cache.appendingPathComponent(".clear-\(UUID().uuidString)")
        try FileStore.mkdir(quarantine)
        var moved: [(URL, URL)] = []
        do {
            for item in items { let dest = quarantine.appendingPathComponent(item.lastPathComponent); try FileStore.fm.moveItem(at: item, to: dest); moved.append((item, dest)) }
        } catch {
            for (item, dest) in moved.reversed() { try? FileStore.fm.moveItem(at: dest, to: item) }
            throw error
        }
        try FileStore.fm.removeItem(at: quarantine)
        return before
    }
}
