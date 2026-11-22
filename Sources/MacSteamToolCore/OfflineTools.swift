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
    public static func definitions(appID: Int, language: String, apiKey: String, achievements: Bool, images: Bool, inventory: Bool, importedInventory: OfflineInventory?) async throws -> (schema: OfflineSchema?, inventory: OfflineInventory?) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = inventory ? importedInventory : nil
        guard !key.isEmpty else { return (nil, items) }
        let schema = achievements ? try await OfflineSchema.fetch(appID: appID, apiKey: key, language: language, withImages: images) : nil
        if inventory && items == nil { items = try await OfflineInventory.fetch(appID: appID, apiKey: key) }
        return (schema, items)
    }

    public static func goldberg(package: URL, gameRoot: URL, appID: Int, dlcs: [Int], accountName: String, language: String, achievements: [Achievement]?, inventory: OfflineInventory? = nil, schema: OfflineSchema? = nil, overlay: Bool = true, destination: URL) throws -> PatchPlan {
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
            let build = overlay ? "experimental" : "regular"
            targets.append((relative, build + (architecture == 0x8664 ? "/x64/steam_api64.dll" : "/x86/steam_api.dll")))
        }
        if let walkError { throw walkError }
        guard !targets.isEmpty, targets.count <= 64 else { throw AppFailure("游戏目录中未找到可替换的 steam_api.dll / steam_api64.dll，或数量异常") }
        try FileStore.mkdir(destination)
        do {
            for (relative, asset) in targets {
                let source = try tool.file(ending: asset, in: package)
                let data = try FileStore.read(source)
                guard try machine(data) == (asset.hasSuffix("/steam_api64.dll") ? 0x8664 : 0x14c) else {
                    throw AppFailure("模拟器 DLL 架构不匹配 / Emulator DLL architecture mismatch")
                }
                let output = try GamePatches.target(relative, root: destination); try FileStore.write(data, to: output)
                let settings = output.deletingLastPathComponent().appendingPathComponent("steam_settings")
                try FileStore.write(Data("\(appID)\n".utf8), to: settings.appendingPathComponent("steam_appid.txt"))
                try FileStore.write(Data("\(appID)\n".utf8), to: output.deletingLastPathComponent().appendingPathComponent("steam_appid.txt"))
                let gameSettings = root.appendingPathComponent(relative).deletingLastPathComponent().appendingPathComponent("steam_settings")
                let existingSaves = gameSettings.appendingPathComponent("FluentOfflineSaves")
                let saveFolder = FileStore.fm.fileExists(atPath: existingSaves.path) ? "FluentOfflineSaves" : "OfflineSaves"
                let user = "[user::general]\naccount_name=\(accountName)\nlanguage=\(language)\n\n[user::saves]\nlocal_save_path=./steam_settings/\(saveFolder)\n"
                let apps = "[app::dlcs]\nunlock_all=0\n" + dlcs.filter { $0 > 0 }.sorted().map { "\($0)=DLC \($0)\n" }.joined()
                let main = "[main::connectivity]\ndisable_networking=1\noffline=1\n"
                for (name, text) in [("configs.user.ini", user), ("configs.app.ini", apps), ("configs.main.ini", main)] { try FileStore.write(Data(text.utf8), to: settings.appendingPathComponent(name)) }
                if overlay {
                    let config = "[overlay::general]\nenable_experimental_overlay=1\ndisable_achievement_notification=0\n"
                    try FileStore.write(Data(config.utf8), to: settings.appendingPathComponent("configs.overlay.ini"))
                }
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
}
