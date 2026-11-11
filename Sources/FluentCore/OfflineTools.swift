import Foundation

public struct ToolPackage: Codable, Sendable {
    public let provider: String; public let version: String; public let source: String; public let archiveSHA256: String
    public let files: [String: String]
    public static func load(_ folder: URL, provider: String) throws -> Self {
        let result = try FileStore.decode(Self.self, at: folder.appendingPathComponent("tool.json"))
        guard result.provider == provider, !result.files.isEmpty else { throw AppFailure("工具包类型不匹配 / Tool package type mismatch") }; return result
    }
    public func file(ending: String, in folder: URL) throws -> URL {
        let found = files.keys.filter { $0 == ending || $0.hasSuffix("/" + ending) }
        guard found.count == 1, let relative = found.first else { throw AppFailure("工具包缺少唯一文件 / Tool package must contain exactly one matching file：\(ending)") }
        let file = try GamePatches.target(relative, root: folder.appendingPathComponent("payload"))
        guard FileStore.hash(try FileStore.read(file)) == files[relative] else { throw AppFailure("工具文件校验失败，请重新下载 / Tool file verification failed; download again：\(relative)") }
        return file
    }
}
public enum OfflineTools {
    public static func machine(_ bytes: Data) throws -> UInt16 {
        guard bytes.count >= 64, bytes[0] == 0x4d, bytes[1] == 0x5a else { throw AppFailure("不是有效的 Windows PE 文件 / Not a valid Windows PE file") }
        let offset = bytes[60..<64].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard offset >= 64, offset <= bytes.count - 6, bytes[offset..<(offset+4)] == Data([0x50,0x45,0,0]) else { throw AppFailure("PE 头无效 / Invalid PE header") }
        let machine = UInt16(bytes[offset+4]) | UInt16(bytes[offset+5]) << 8
        guard machine == 0x14c || machine == 0x8664 else { throw AppFailure("仅支持 Windows x86 / x64 游戏") }; return machine
    }
    public static func goldberg(package: URL, gameRoot: URL, appID: Int, dlcs: [Int], accountName: String, language: String, lan: Bool, achievements: [Achievement]?, inventory: OfflineInventory? = nil, schema: OfflineSchema? = nil, destination: URL) throws -> PatchPlan {
        let tool = try ToolPackage.load(package, provider: "goldberg")
        guard !FileStore.fm.fileExists(atPath: destination.path), UInt32(exactly: appID) != nil, appID > 0,
              !accountName.isEmpty, accountName.count <= 80, !accountName.contains(where: { "\r\n\0".contains($0) }), ["english", "schinese"].contains(language) else { throw AppFailure("离线配置或缓存目录无效 / Invalid offline configuration or cache directory") }
        let root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        var walkError: Error?
        guard let walk = FileStore.fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, e in walkError = e; return false }) else { throw AppFailure("无法读取游戏目录 / Cannot read the game directory") }
        var targets: [(String, String)] = []
        for case let file as URL in walk {
            let name = file.lastPathComponent.lowercased()
            if (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { walk.skipDescendants(); continue }
            guard name == "steam_api.dll" || name == "steam_api64.dll" else { continue }
            let architecture = try machine(FileStore.read(file))
            guard (name == "steam_api.dll" && architecture == 0x14c) || (name == "steam_api64.dll" && architecture == 0x8664) else { throw AppFailure("Steam API 文件名与 PE 架构不一致 / Steam API filename does not match its PE architecture") }
            let components = file.standardizedFileURL.pathComponents
            guard components.starts(with: root.pathComponents) else { throw AppFailure("Steam API 文件位于目标目录以外 / Steam API file is outside the target directory") }
            let relative = components.dropFirst(root.pathComponents.count).joined(separator: "/")
            targets.append((relative, architecture == 0x8664 ? "regular/x64/steam_api64.dll" : "regular/x86/steam_api.dll"))
        }
        if let walkError { throw walkError }
        guard !targets.isEmpty, targets.count <= 64 else { throw AppFailure("游戏目录中未找到可替换的 steam_api.dll / steam_api64.dll，或数量异常") }
        try FileStore.mkdir(destination)
        do {
            for (relative, asset) in targets {
                let source = try tool.file(ending: asset, in: package)
                let data = try FileStore.read(source); _ = try machine(data)
                let output = try GamePatches.target(relative, root: destination); try FileStore.write(data, to: output)
                let settings = output.deletingLastPathComponent().appendingPathComponent("steam_settings")
                try FileStore.write(Data("\(appID)\n".utf8), to: settings.appendingPathComponent("steam_appid.txt"))
                try FileStore.write(Data("\(appID)\n".utf8), to: output.deletingLastPathComponent().appendingPathComponent("steam_appid.txt"))
                let user = "[user::general]\naccount_name=\(accountName)\nlanguage=\(language)\n\n[user::saves]\nlocal_save_path=./steam_settings/FluentOfflineSaves\n"
                let apps = "[app::dlcs]\nunlock_all=0\n" + dlcs.filter { $0 > 0 }.sorted().map { "\($0)=DLC \($0)\n" }.joined()
                let main = "[main::connectivity]\ndisable_networking=\(lan ? 0 : 1)\noffline=\(lan ? 0 : 1)\n"
                for (name, text) in [("configs.user.ini", user), ("configs.app.ini", apps), ("configs.main.ini", main)] { try FileStore.write(Data(text.utf8), to: settings.appendingPathComponent(name)) }
                if let inventory {
                    try FileStore.json(inventory.items, to: settings.appendingPathComponent("items.json"))
                    try FileStore.json(inventory.quantities, to: settings.appendingPathComponent("default_items.json"))
                }
                if let schema {
                    try FileStore.write(schema.json(), to: settings.appendingPathComponent("achievements.json"))
                    try FileStore.write(schema.statsJSON(), to: settings.appendingPathComponent("stats.json"))
                    for (relative, bytes) in schema.images {
                        guard relative.hasPrefix("achievement_images/"), bytes.count <= 4 * 1024 * 1024 else { throw AppFailure("成就图片无效 / Invalid achievement image") }
                        try FileStore.write(bytes, to: try GamePatches.target(relative, root: settings))
                    }
                } else if let achievements {
                    let schema: [[String: Any]] = achievements.map { ["name": $0.id, "displayName": $0.name, "description": $0.detail, "hidden": 0] }
                    try FileStore.write(JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .prettyPrinted]), to: settings.appendingPathComponent("achievements.json"))
                }
            }
            return try GamePatches.plan(package: destination, gameRoot: root, appID: appID)
        } catch { try? FileStore.fm.removeItem(at: destination); throw error }
    }
    /// One preview, backup, install receipt and restore operation for both tools.
    public static func combined(_ plans: [PatchPlan]) throws -> PatchPlan {
        guard let first = plans.first, plans.count >= 2, plans.allSatisfy({ $0.appID == first.appID && $0.gameRoot == first.gameRoot && $0.registry == nil }) else { throw AppFailure("离线处理目标不一致 / Offline plans have different targets") }
        var entries: [String: PatchEntry] = [:]; var total = 0
        for plan in plans {
            for entry in plan.entries {
                let key = entry.relative.precomposedStringWithCanonicalMapping.lowercased()
                if let old = entries[key] {
                    guard old.relative == entry.relative, old.data == entry.data, old.originalHash == entry.originalHash else { throw AppFailure("离线处理输出冲突 / Conflicting offline outputs：\(entry.relative)") }
                } else { entries[key] = entry; total += entry.data.count }
            }
        }
        guard entries.count <= 10000, total <= 512 * 1024 * 1024 else { throw AppFailure("离线输出超过限制 / Offline output exceeds the size limit") }
        return PatchPlan(appID: first.appID, gameRoot: first.gameRoot, source: "Steamless + Goldberg", entries: entries.values.sorted { $0.relative < $1.relative })
    }
    public static func steamless(package: URL, executable: URL, gameRoot: URL, appID: Int, paths: AppPaths, bridge: URL, destination: URL) async throws -> PatchPlan {
        let tool = try ToolPackage.load(package, provider: "steamless")
        let api = try tool.file(ending: "Plugins/Steamless.API.dll", in: package)
        // Every executable plugin/dependency must still match the downloaded archive.
        for name in tool.files.keys where name.hasPrefix("Plugins/") && name.hasSuffix(".dll") { _ = try tool.file(ending: name, in: package) }
        _ = try WineOverrides.executable(executable, inside: gameRoot)
        let source = executable.resolvingSymlinksInPath().standardizedFileURL, root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        let relative = source.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        let original = try FileStore.read(source), arch = try machine(original)
        guard !FileStore.fm.fileExists(atPath: destination.path) else { throw AppFailure("请选择新的工作目录 / Select a new working directory") }
        let work = destination.appendingPathComponent("work"), payload = destination.appendingPathComponent("payload")
        try FileStore.fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let inputExe = work.appendingPathComponent("input.exe"), request = work.appendingPathComponent("request.json"), response = work.appendingPathComponent("response.json")
        try FileStore.write(original, to: inputExe)
        let r = ["operation": "unpack", "plugins": try WineLaunch.windowsPath(api.deletingLastPathComponent().path), "file": try WineLaunch.windowsPath(inputExe.path)]
        try FileStore.json(r, to: request)
        var launch = try WineLaunch.prepare(appID: appID, command: bridge.path, paths: paths)
        launch.environment["DOTNET_EnableWriteXorExecute"] = "0"
        launch.arguments += [try WineLaunch.windowsPath(request.path), try WineLaunch.windowsPath(response.path)]
        let process = try launch.launch(log: destination.appendingPathComponent("steamless.log"))
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        if process.isRunning { process.terminate(); throw AppFailure("Steamless 处理超时，原始游戏文件未修改 / Steamless timed out; original game file is unchanged") }
        process.waitUntilExit()
        guard let result = try JSONSerialization.jsonObject(with: FileStore.read(response)) as? [String: Any], result["ok"] as? Bool == true else {
            let json = (try? JSONSerialization.jsonObject(with: FileStore.read(response))) as? [String: Any]
            throw AppFailure(json?["error"] as? String ?? "Steamless 未返回成功结果 / Steamless did not return a successful result")
        }
        let data = try FileStore.read(work.appendingPathComponent("input.exe.unpacked.exe"))
        guard try machine(data) == arch, data != original else { throw AppFailure("Steamless 输出校验失败 / Steamless output verification failed") }
        try FileStore.write(data, to: try GamePatches.target(relative, root: payload))
        let plan = try GamePatches.plan(package: payload, gameRoot: root, appID: appID)
        guard plan.entries.first?.originalHash == FileStore.hash(original) else { throw AppFailure("处理期间原始游戏文件发生变化 / Original game file changed during processing") }
        return plan
    }
}
