import Foundation
import Darwin

public enum CloudProvider: String, CaseIterable, Identifiable, Sendable {
    case local, folder, webdav, s3, r2, gdrive, onedrive
    public var id: String { rawValue }
    public var title: String { switch self { case .local: "本机缓存 / Local cache"; case .folder: "文件夹 / Folder"; case .webdav: "WebDAV"; case .s3: "S3"; case .r2: "Cloudflare R2"; case .gdrive: "Google Drive"; case .onedrive: "OneDrive" } }
}
public struct CloudConfiguration: Sendable {
    public var enabled = false
    public var apps = ""
    public var automaticApps = false
    public var excludedApps = ""
    public var statsApps = ""
    public var syncAchievements = false
    public var syncPlaytime = false
    public var provider: CloudProvider = .local
    public var folder = ""
    public init() {}
    public static func load(paths: AppPaths) throws -> Self {
        let url = paths.data.appendingPathComponent("CloudRedirect/config.json")
        guard FileStore.fm.fileExists(atPath: url.path) else { return Self() }
        let j = try JSONSerialization.jsonObject(with: FileStore.read(url)) as? [String: Any] ?? [:]
        var c = Self(); c.enabled = j["enabled"] as? Bool ?? false
        c.apps = (j["apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
        c.automaticApps = j["automatic_apps"] as? Bool ?? false
        c.excludedApps = (j["excluded_apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
        c.statsApps = (j["stats_apps"] as? [Int] ?? []).map(String.init).joined(separator: ", ")
        c.syncAchievements = j["sync_achievements"] as? Bool ?? false
        c.syncPlaytime = j["sync_playtime"] as? Bool ?? false
        c.provider = CloudProvider(rawValue: j["provider"] as? String ?? "") ?? .local
        c.folder = (j["token_paths"] as? [String: String])?["folder"] ?? ""
        return c
    }
    public static func localDefaults(paths: AppPaths) -> Self {
        var c = Self(); c.enabled = true; c.automaticApps = true; c.provider = .folder
        c.folder = paths.data.appendingPathComponent("CloudSaves").path
        return c
    }
    public static func parseIDs(_ text: String) throws -> [Int] {
        let parts = text.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init)
        let ids = parts.compactMap(TextUtil.validID)
        guard parts.count == ids.count, ids.count <= 4096 else { throw AppFailure("AppID 列表无效或超过 4096 项 / Invalid AppID list or over 4096 entries") }
        return Array(Set(ids)).sorted()
    }
    public func selectedApps(paths: AppPaths) throws -> [Int] {
        guard enabled else { return [] }
        if !automaticApps { return try Self.parseIDs(apps) }
        let mac = try MacSteamConfig.parse(FileStore.text(paths.config))
        let excluded = Set(try Self.parseIDs(excludedApps))
        return mac.apps.filter { mac.parents[$0] == nil && !excluded.contains($0) }.sorted()
    }
    public func save(paths: AppPaths, validate: () throws -> Void = {}) throws {
        let parts = apps.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init)
        let ids = parts.compactMap(TextUtil.validID)
        guard parts.count == ids.count else { throw AppFailure("AppID 必须为有效正整数，用逗号或空格分隔 / AppIDs must be positive integers separated by commas or spaces") }
        let excluded = try Self.parseIDs(excludedApps)
        guard !enabled || automaticApps || !ids.isEmpty else { throw AppFailure("启用前请明确选择需要重定向的 AppID / Select AppIDs to redirect before enabling") }
        if enabled && automaticApps { _ = try selectedApps(paths: paths) }
        let statsParts = statsApps.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init)
        let statIDs = statsParts.compactMap(TextUtil.validID)
        guard statsParts.count == statIDs.count, !(syncAchievements || syncPlaytime) || !statIDs.isEmpty else { throw AppFailure("统计同步需要明确的有效 AppID 列表 / Statistics sync requires an explicit list of valid AppIDs") }
        if provider == .folder {
            guard folder.hasPrefix("/"), !folder.contains("\0") else { throw AppFailure("请选择云存档文件夹 / Select the cloud save folder") }
            let root = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
            for excluded in [paths.steam, paths.data.appendingPathComponent("CloudRedirect")] {
                let p = excluded.resolvingSymlinksInPath().path
                guard root != p, !root.hasPrefix(p + "/"), !p.hasPrefix(root + "/") else { throw AppFailure("云文件夹必须独立于 Steam 数据和本地缓存 / Cloud folder must be separate from Steam data and local caches") }
            }
        }
        let url = paths.data.appendingPathComponent("CloudRedirect/config.json")
        let old = FileStore.fm.fileExists(atPath: url.path) ? try FileStore.read(url) : nil
        var j = try old.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] } ?? [:]
        var tokens = j["token_paths"] as? [String: String] ?? [:]
        if !folder.isEmpty { tokens["folder"] = folder }
        j["enabled"] = enabled; j["apps"] = Array(Set(ids)).sorted(); j["provider"] = provider.rawValue
        j["automatic_apps"] = automaticApps; j["excluded_apps"] = excluded
        if automaticApps { j["macsteam_config"] = paths.config.path }
        j["token_paths"] = tokens; j["stats_sync_enabled"] = syncAchievements || syncPlaytime
        j["stats_apps"] = Array(Set(statIDs)).sorted(); j["sync_achievements"] = syncAchievements; j["sync_playtime"] = syncPlaytime
        let data = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys])
        func commit() throws {
            try FileTransaction(backupRoot: paths.backups).apply([(url, data)], reason: "云存档配置", expectations: [url: old.map(FileStore.hash) ?? "missing"], validate: validate)
        }
        let oldJSON = try old.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] ?? [:] } ?? [:]
        let oldFolder = (oldJSON["token_paths"] as? [String: String])?["folder"] ?? ""
        if provider == .folder, oldFolder.hasPrefix("/"), !oldFolder.isEmpty, oldFolder != folder {
            try DirectoryMigration.apply(from: URL(fileURLWithPath: oldFolder), to: URL(fileURLWithPath: folder), selection: .all,
                                         lockRoot: paths.backups, validate: validate, commit: commit)
        } else { try commit() }
    }
}
public enum CloudEngine {
    public static func credentialsURL(_ provider: CloudProvider, paths: AppPaths) -> URL {
        let name = [CloudProvider.webdav: "webdav_credentials.json", .s3: "s3_credentials.json", .r2: "r2_credentials.json"][provider] ?? "tokens_\(provider.rawValue).json"
        return paths.data.appendingPathComponent("CloudRedirect/" + name)
    }
    public static func saveCredentials(_ fields: [String: String], provider: CloudProvider, paths: AppPaths) throws {
        guard ![.local, .folder].contains(provider) else { throw AppFailure("此服务商无需凭证 / This provider does not require credentials") }
        let values = try CloudOnline.credentialValues(fields, provider: provider)
        let url = try effectiveCredentialsURL(provider, paths: paths)
        try FileStore.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        let temp = url.deletingLastPathComponent().appendingPathComponent(".credential-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: temp) }
        guard FileStore.fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw AppFailure("无法保存服务商凭证 / Cannot save provider credentials") }
        guard rename(temp.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
    public static func effectiveCredentialsURL(_ provider: CloudProvider, paths: AppPaths) throws -> URL {
        let config = paths.data.appendingPathComponent("CloudRedirect/config.json")
        guard FileStore.fm.fileExists(atPath: config.path) else { return credentialsURL(provider, paths: paths) }
        let json = try JSONSerialization.jsonObject(with: FileStore.read(config)) as? [String: Any] ?? [:]
        let registry = (json["token_paths"] as? [String: String])?[provider.rawValue]
        let legacy = (json["provider"] as? String)?.lowercased() == provider.rawValue ? json["token_path"] as? String : nil
        guard let path = [registry, legacy].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return credentialsURL(provider, paths: paths) }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw AppFailure("已保存的凭证路径无效 / Invalid saved credential path") }
        return URL(fileURLWithPath: path)
    }
    public static func run(_ arguments: [String], executable: URL, paths: AppPaths, timeout: TimeInterval = 180) async throws -> String {
        guard FileStore.fm.isExecutableFile(atPath: executable.path) else { throw AppFailure("缺少云存档引擎，请重新完整打包应用 / Cloud engine missing; rebuild the complete application") }
        let dir = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentCloud-\(UUID().uuidString)")
        try FileStore.fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileStore.fm.removeItem(at: dir) }
        let output = dir.appendingPathComponent("result.json")
        FileStore.fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        var env = ProcessInfo.processInfo.environment; env["FLUENT_CLOUD_ROOT"] = paths.data.path; env["FLUENT_CLOUD_STEAM"] = paths.steam.path
        p.environment = env; p.standardOutput = handle; p.standardError = FileHandle.nullDevice
        let task = Task.detached {
            try Task.checkCancellation(); try p.run()
            let end = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < end && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }
            if p.isRunning {
                p.terminate(); try? await Task.sleep(for: .milliseconds(250)); if p.isRunning { kill(p.processIdentifier, SIGKILL) }; p.waitUntilExit()
                if arguments.first == "probe-provider" {
                    throw AppFailure("在线测试已取消或超时；0/0 目录可能留有 fluent-connection-test 临时文件，尚未确认清理。未操作游戏存档 / Online test cancelled or timed out; a temporary fluent-connection-test object may remain under 0/0. Cleanup is unconfirmed. No game saves were used")
                }
                throw AppFailure("云存档任务已取消或超时；迁移目标可能已部分写入，请检查后重试 / Cloud task cancelled or timed out; a migration destination may be partially written. Check before retrying")
            }
            p.waitUntilExit(); let text = try FileStore.text(output)
            guard p.terminationStatus == 0 else { throw AppFailure(text.isEmpty ? "云存档引擎失败 / Cloud engine failed：\(p.terminationStatus)" : String(text.suffix(12000))) }
            return text
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
