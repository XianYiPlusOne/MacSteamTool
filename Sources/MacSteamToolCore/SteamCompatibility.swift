import Foundation

public enum SteamCompatibility {
    public struct Tool: Identifiable, Sendable {
        public let id: String
        public let name: String
    }
    private static let path = ["InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"]
    public static func tools(paths: AppPaths) throws -> [Tool] {
        var result: [Tool] = []; var seen = Set<String>()
        for folder in FileStore.files(paths.steam.appendingPathComponent("compatibilitytools.d")) {
            let file = folder.appendingPathComponent("compatibilitytool.vdf")
            guard FileStore.fm.fileExists(atPath: file.path) else { continue }
            let doc = try VDF.parse(FileStore.text(file))
            for entry in doc.object("compatibilitytools")?.object("compat_tools")?.entries ?? [] {
                guard let value = entry.children,
                      value.string("from_oslist")?.split(separator: ",").contains("windows") == true,
                      value.string("to_oslist")?.split(separator: ",").contains("macos") == true else { continue }
                guard validTool(entry.key), seen.insert(entry.key).inserted else { throw AppFailure("运行器标识无效或重复 / Invalid or duplicate compatibility tool identifier") }
                result.append(Tool(id: entry.key, name: value.string("display_name") ?? entry.key))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func validTool(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
    private static func child(_ node: VDF, key: String, required: Bool) throws -> VDF {
        let matches = node.entries.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        guard matches.count <= 1, matches.isEmpty || matches[0].children != nil, !required || !matches.isEmpty else { throw AppFailure("Steam 兼容性配置结构无效或重复 / Invalid or duplicate Steam compatibility configuration") }
        return matches.first?.children ?? VDF()
    }
    public static func mapping(_ bytes: Data, appID: Int) throws -> VDF? {
        guard TextUtil.validID(String(appID)) != nil, bytes.count <= 8 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else { throw AppFailure("AppID 或 Steam 配置无效 / Invalid AppID or Steam configuration") }
        var node = try VDF.parse(text)
        for (index, key) in path.enumerated() { node = try child(node, key: key, required: index < 4) }
        let matches = node.entries.filter { $0.key == String(appID) }
        guard matches.count <= 1, matches.isEmpty || matches[0].children != nil else { throw AppFailure("此 AppID 的兼容性设置重复或无效 / Duplicate or invalid app compatibility setting") }
        return matches.first?.children
    }
    static func selectedTool(_ data: Data?, appID: Int) -> String? {
        guard let data else { return nil }
        if let mapping = try? mapping(data, appID: appID) { return mapping.string("name") }
        return try? globalTool(data)
    }
    public static func globalTool(_ bytes: Data) throws -> String? {
        _ = try mapping(bytes, appID: 1)
        var node = try VDF.parse(String(decoding: bytes, as: UTF8.self))
        for (index, key) in path.enumerated() { node = try child(node, key: key, required: index < 4) }
        return try child(node, key: "0", required: false).string("name")
    }
    /// Seed a fresh configuration; an existing global choice (including an
    /// explicit empty/automatic choice) and every per-game mapping are retained.
    public static func seedDefault(_ bytes: Data?, tool: String, replacingExisting: Bool = false) throws -> Data {
        guard validTool(tool) else { throw AppFailure("Invalid default compatibility tool") }
        var doc = try bytes.map { try VDF.parse(String(decoding: $0, as: UTF8.self)) } ?? VDF()
        if let bytes { _ = try globalTool(bytes) }
        var changed = false
        func fill(_ node: inout VDF, depth: Int) throws {
            if depth == path.count {
                if !replacingExisting, node.entries.contains(where: { $0.key == "0" }) { return }
                var value = VDF(); value.set("name", value: tool); value.set("config", value: ""); value.set("priority", value: "75")
                node.set("0", object: value); changed = true; return
            }
            let key = path[depth]; var nested = try child(node, key: key, required: bytes != nil && depth < 4)
            try fill(&nested, depth: depth + 1); node.set(key, object: nested)
        }
        try fill(&doc, depth: 0)
        return changed ? Data(doc.serialized().utf8) : (bytes ?? Data(doc.serialized().utf8))
    }
    /// An explicit backend choice changes only the default, never per-game mappings.
    public static func chooseDefault(paths: AppPaths, tool: String, requireIdle: () throws -> Void = {
        guard !SteamProcesses.isRunning else { throw AppFailure("请退出 Steam 后继续 / Quit Steam to continue") }
    }) throws {
        try requireIdle()
        guard try tools(paths: paths).contains(where: { $0.id == tool }) else { throw AppFailure("兼容层尚未就绪 / Translation backend is not ready") }
        let file = paths.steam.appendingPathComponent("config/config.vdf")
        let before = FileStore.fm.fileExists(atPath: file.path) ? try FileStore.read(file) : nil
        if let before, try globalTool(before) == tool { return }
        let after = try seedDefault(before, tool: tool, replacingExisting: true)
        _ = try FileTransaction(backupRoot: paths.data.appendingPathComponent("CompatibilityBackups")).apply([(file, after)], reason: "Default translation backend: \(tool)", expectations: [file: before.map(FileStore.hash) ?? "missing"], validate: requireIdle)
    }
    public static func edit(_ bytes: Data, appID: Int, tool: String?) throws -> Data {
        _ = try mapping(bytes, appID: appID)
        guard tool == nil || tool == "" || validTool(tool!) else { throw AppFailure("运行器标识无效 / Invalid compatibility tool identifier") }
        var doc = try VDF.parse(String(decoding: bytes, as: UTF8.self))
        func change(_ node: inout VDF, depth: Int) throws {
            if depth == path.count {
                node.entries.removeAll { $0.key == String(appID) }
                if let tool {
                    var value = VDF(); value.set("name", value: tool); value.set("config", value: ""); value.set("priority", value: "250")
                    node.set(String(appID), object: value)
                }
                return
            }
            let key = path[depth]; var nested = try child(node, key: key, required: depth < 4)
            try change(&nested, depth: depth + 1); node.set(key, object: nested)
        }
        try change(&doc, depth: 0)
        return Data(doc.serialized().utf8)
    }
    @discardableResult public static func save(paths: AppPaths, appID: Int, tool: String?, requireIdle: () throws -> Void = GameContainers.requireIdle) throws -> BackupRecord {
        try requireIdle()
        if let tool, !tool.isEmpty { guard try tools(paths: paths).contains(where: { $0.id == tool }) else { throw AppFailure("所选 Windows 运行器尚未安装 / Selected Windows compatibility tool is not installed") } }
        let file = paths.steam.appendingPathComponent("config/config.vdf"), before = try FileStore.read(file)
        let after = try edit(before, appID: appID, tool: tool)
        let manual = try AutomaticCompatibility.manualChange(paths: paths, appID: appID)
        let backups = paths.data.appendingPathComponent("CompatibilityBackups")
        try FileStore.mkdir(backups); try FileStore.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.path)
        return try FileTransaction(backupRoot: backups).apply([(file, after), (manual.url, manual.data)], reason: "Steam Play AppID \(appID): \(tool ?? "automatic")", expectations: [file: FileStore.hash(before), manual.url: manual.expected], validate: requireIdle)
    }
}
