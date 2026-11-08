import Foundation

/// Read-only native inventory; only Steam remote and matching AutoCloud files are included.
public struct CloudSaveInventory: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let appID: Int
        public let path: String
        public init(appID: Int, path: String) { self.appID = appID; self.path = path }
    }
    public let success: Bool
    public let apps: [Int]
    public let files: [Entry]
    public init(apps: [Int], files: [Entry]) { success = true; self.apps = apps; self.files = files }
}

public enum CloudActivation {
    /// Never modifies a game's files. Refuses activation if a source changes or Steam starts.
    @discardableResult public static func save(_ config: CloudConfiguration, inventory: CloudSaveInventory?, paths: AppPaths,
                                             steamRunning: () -> Bool = { SteamProcesses.isRunning }) throws -> URL? {
        func stopped() throws {
            guard !steamRunning() else { throw AppFailure("请先退出 Steam，再备份并启用云存档接管 / Quit Steam before backing up and activating cloud saves") }
        }
        try stopped()
        let selected = try config.selectedApps(paths: paths)
        let sourceConfig = config.automaticApps && config.enabled ? try FileStore.read(paths.config) : nil
        var backup: URL?
        var hashes: [String: String] = [:]
        var records: [[String: String]] = []
        if config.enabled {
            guard let inventory, inventory.success, Set(inventory.apps) == Set(selected), inventory.files.count <= 100_000,
                  inventory.files.allSatisfy({ selected.contains($0.appID) }) else { throw AppFailure("存档清单不完整或游戏范围已变化；未启用 / Incomplete save inventory or changed game scope; not enabled") }
            let folder = paths.backups.appendingPathComponent("CloudActivation-" + UUID().uuidString)
            try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            backup = folder
            // The marker remains on any failure. Never turn an incomplete backup into success.
            try FileStore.write(Data("Backup in progress; configuration not applied".utf8), to: folder.appendingPathComponent(".INCOMPLETE"))
            var total = 0
            for entry in inventory.files {
                try stopped()
                guard entry.path.hasPrefix("/"), !entry.path.contains("\0") else { throw AppFailure("存档路径无效 / Invalid save path") }
                let source = URL(fileURLWithPath: entry.path).standardizedFileURL
                guard source.resolvingSymlinksInPath().standardizedFileURL == source else { throw AppFailure("存档路径含符号链接；请检查实际位置 / Save path contains a symbolic link") }
                if hashes[source.path] != nil { continue }
                let before = FileStore.fingerprint(source), data = try FileStore.read(source)
                total += data.count
                guard total <= 8 * 1024 * 1024 * 1024 else { throw AppFailure("存档备份超过 8 GB；未启用 / Save backup exceeds 8 GB; not enabled") }
                let stored = "\(records.count).save", target = folder.appendingPathComponent(stored)
                try FileStore.write(data, to: target)
                let hash = FileStore.hash(data)
                guard before == FileStore.fingerprint(source), FileStore.hash(try FileStore.read(source)) == hash,
                      FileStore.hash(try FileStore.read(target)) == hash else { throw AppFailure("存档变化或备份校验失败；未启用 / Save changed or backup verification failed; not enabled") }
                hashes[source.path] = hash
                records.append(["source": source.path, "stored": stored, "sha256": hash, "appID": String(entry.appID)])
            }
            try FileStore.json(records, to: folder.appendingPathComponent("files.json"))
        }
        try config.save(paths: paths) {
            try stopped()
            if let sourceConfig { guard try FileStore.read(paths.config) == sourceConfig else { throw AppFailure("macSteam 游戏列表已变化；请重新扫描 / macSteam game list changed; scan again") } }
            for (path, hash) in hashes {
                guard FileStore.hash(try FileStore.read(URL(fileURLWithPath: path))) == hash else { throw AppFailure("存档在启用前发生变化；未写入配置 / Save changed before activation; configuration not written") }
            }
        }
        if let backup { try FileStore.fm.removeItem(at: backup.appendingPathComponent(".INCOMPLETE")) }
        return backup
    }
}

public struct CloudRuntimeStatus: Decodable, Sendable {
    public let pid: Int32
    public let cloudProvider: String?
    public let cloudConfigSHA256: String?
    public let cloudReady: Bool?
    public let cloudAppsLoaded: UInt?
    public let cloudRequests: UInt?
    public let cloudFailures: UInt?
    public let cloudLastAppID: UInt?
    public let cloudLastResult: Int?
    public static func current(paths: AppPaths, pids: [Int32] = SteamProcesses.pids()) -> Self? {
        guard let value = try? FileStore.decode(Self.self, at: paths.data.appendingPathComponent("CloudRedirect/runtime-status.json")),
              pids.contains(value.pid) else { return nil }
        return value
    }
    public func needsRestart(paths: AppPaths) -> Bool {
        guard let cloudConfigSHA256 else { return true }
        let url = paths.data.appendingPathComponent("CloudRedirect/config.json")
        guard FileStore.fm.fileExists(atPath: url.path) else { return cloudConfigSHA256 != "missing" }
        guard let data = try? FileStore.read(url) else { return true }
        return FileStore.hash(data) != cloudConfigSHA256
    }
}
