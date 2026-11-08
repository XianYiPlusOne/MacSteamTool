import Foundation

/// Workshop content can use a depot whose ID is the consumer AppID. It is not
/// necessarily listed in appinfo's normal game depots. Keep its supplied key too.
public enum WorkshopKeys {
    public static func adding(_ key: String, to document: LuaDocument) throws -> LuaDocument {
        guard TextUtil.validKey(key) else { throw AppFailure("工坊仓库密钥格式无效 / Invalid Workshop depot key") }
        let id = document.appID, key = key.lowercased()
        let existing = document.entries.filter { $0.id == id && $0.key != nil }
        if !existing.isEmpty {
            guard existing.allSatisfy({ $0.owner == id && $0.key == key }) else { throw AppFailure("Lua 中的工坊密钥或归属冲突；未覆盖 / Conflicting Workshop key or owner in Lua; nothing overwritten") }
            return document
        }
        var lines = document.raw.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { !TextUtil.matches("(?i)^\\s*addappid\\s*\\(\\s*\(id)\\s*(?:,|\\))", $0).isEmpty }) else { throw AppFailure("未找到主游戏声明 / Main game declaration not found") }
        let cr = lines[index].hasSuffix("\r") ? "\r" : ""
        lines.insert("addappid(\(id), 1, \"\(key)\")" + cr, at: index + 1)
        return try LuaDocument.parse(lines.joined(separator: "\n"), suggestedID: id)
    }

    /// Repairs only the selected enabled base game, using a supplied Lua key or
    /// the existing local key cache. Existing keys are never silently replaced.
    @discardableResult public static func repair(appID: Int, paths: AppPaths) throws -> BackupRecord? {
        let before = try FileStore.read(paths.config)
        guard let text = String(data: before, encoding: .utf8) else { throw AppFailure("macSteam 配置不是 UTF-8 / macSteam configuration is not UTF-8") }
        var config = try MacSteamConfig.parse(text)
        guard config.topLevel.contains(appID) else { throw AppFailure("请先启用该主游戏 / Enable this base game first") }
        let lua = paths.lua.appendingPathComponent("\(appID).lua")
        let luaBefore = FileStore.fm.fileExists(atPath: lua.path) ? try FileStore.read(lua) : nil
        let document = try luaBefore.map { data -> LuaDocument in
            guard let text = String(data: data, encoding: .utf8) else { throw AppFailure("Lua 不是 UTF-8 / Lua is not UTF-8") }
            return try LuaDocument.parse(text, suggestedID: appID)
        }
        let luaKey = document?.entries.first { $0.id == appID && $0.key != nil }?.key
        let key: String
        if let existing = config.keys[appID]?[appID] ?? luaKey { key = existing }
        else {
            let cache = paths.cache.appendingPathComponent("depotkeys.json")
            guard let data = try? FileStore.read(cache),
                  let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cached = raw[String(appID)] as? String, TextUtil.validKey(cached) else {
                throw AppFailure("缓存没有该游戏的工坊仓库密钥；请更新密钥缓存后重试。未改动配置 / Workshop depot key unavailable; refresh the key cache and retry. Configuration unchanged")
            }
            key = cached.lowercased()
        }
        var changes: [(URL, Data?)] = [], expectations = [paths.config: FileStore.hash(before)]
        if let document, let luaBefore {
            let after = Data(try adding(key, to: document).raw.utf8)
            expectations[lua] = FileStore.hash(luaBefore)
            if after != luaBefore { changes.append((lua, after)) }
        }
        if config.keys[appID]?[appID] == nil {
            config.keys[appID, default: [:]][appID] = key
            try config.validate()
            changes.append((paths.config, Data(config.serialized().utf8)))
        }
        guard !changes.isEmpty else { return nil }
        return try FileTransaction(backupRoot: paths.backups).apply(changes, reason: "补齐工坊仓库密钥 / Repair Workshop depot key · \(appID)", expectations: expectations)
    }
}
