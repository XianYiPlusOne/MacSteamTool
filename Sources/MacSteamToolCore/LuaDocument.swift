import Foundation

public struct LuaEntry: Equatable, Sendable {
    public var id: Int
    public var key: String?
    public var name: String
    public var owner: Int
}
public struct ManifestPin: Equatable, Sendable {
    public var depot: Int
    public var manifest: String
    public var active: Bool
}
public struct LuaDocument: Sendable {
    static let versionPinNotice = "版本锁定需安装 MacSteamTool Manifest 扩展并缓存对应 Manifest；当前仅支持 Steam build 1792618285 的 public 分支 / Version pinning requires MacSteamTool Manifest and the matching cached manifest; currently supports Steam build 1792618285 public branch"
    public var raw: String
    public var appID: Int
    public var entries: [LuaEntry]
    public var pins: [ManifestPin]
    public var tokens: [Int: String]
    public var warnings: [String]
    public var name: String { entries.first(where: { $0.id == appID })?.name ?? "" }
    public var dlcIDs: [Int] { Array(Set(entries.filter { $0.key == nil && $0.id != appID }.map(\.id))).sorted() }
    public var depots: [LuaEntry] { entries.filter { $0.key != nil } }

    /// Parses known statements as data. Imported Lua is never executed.
    public static func parse(_ text: String, suggestedID: Int? = nil) throws -> LuaDocument {
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw AppFailure("Lua 超过 8 MB 限制 / Lua exceeds the 8 MB limit") }
        let stripped = text.replacingOccurrences(of: #"(?s)--\[(=*)\[.*?\]\1\]"#, with: "", options: .regularExpression)
        var entries: [LuaEntry] = []; var pins: [ManifestPin] = []; var tokens: [Int: String] = [:]; var warnings: [String] = []
        var main = suggestedID; var owner = suggestedID ?? 0
        for rawLine in stripped.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let commented = line.hasPrefix("--")
            let pinLine = commented ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) : line
            if let m = TextUtil.matches(#"(?i)^setmanifestid\s*\(\s*(\d+)\s*,\s*['"](\d+)['"]\s*(?:,\s*\d+\s*)?\)"#, pinLine).first,
               let id = TextUtil.validID(m[1]), UInt64(m[2]) != nil { pins.append(ManifestPin(depot: id, manifest: m[2], active: !commented)); continue }
            if commented || line.isEmpty { continue }
            if let m = TextUtil.matches(#"(?i)^addappid\s*\(\s*(\d+)\s*(?:,\s*\d+\s*(?:,\s*['"]([^'"]*)['"]\s*)?)?\)\s*(?:--\s*(.*))?$"#, line).first {
                guard let id = TextUtil.validID(m[1]) else { throw AppFailure("无效的 AppID / DepotID") }
                if main == nil { main = id; owner = id }
                let key = m[2].isEmpty ? nil : m[2].lowercased()
                if let key, !TextUtil.validKey(key) { throw AppFailure("Depot \(id) 的密钥必须是 64 位十六进制字符串 / key must contain 64 hexadecimal characters") }
                if key == nil { owner = id }
                entries.append(LuaEntry(id: id, key: key, name: m[3], owner: owner == 0 ? id : owner))
            } else if let m = TextUtil.matches(#"(?i)^addtoken\s*\(\s*(\d+)\s*,\s*['"](\d+)['"]\s*\)"#, line).first, let id = TextUtil.validID(m[1]) {
                guard let token = UInt64(m[2]), tokens[id] == nil || tokens[id] == String(token) else { throw AppFailure("访问令牌溢出或重复冲突 / Access token overflow or conflicting duplicate") }
                tokens[id] = String(token)
            } else { warnings.append("未转换语句 / Unconverted statement：\(String(line.prefix(100)))") }
        }
        guard let appID = main, entries.contains(where: { $0.id == appID }) else { throw AppFailure("未找到主游戏的 addappid；文件名与内容必须一致 / Main addappid missing; filename and contents must match") }
        if !tokens.isEmpty { warnings.append("addtoken 需要安装 MacSteamTool 原生运行时扩展；仅用于已启用的对应 AppID / addtoken requires the MacSteamTool native runtime and applies only to the enabled matching AppID") }
        if pins.contains(where: \.active) { warnings.append(versionPinNotice) }
        return LuaDocument(raw: text, appID: appID, entries: entries, pins: pins, tokens: tokens, warnings: warnings)
    }

    public func pinning(_ manifests: [Int: String]?) throws -> LuaDocument {
        let lines = raw.components(separatedBy: .newlines).filter {
            TextUtil.matches(#"(?i)^\s*(?:--\s*)?setmanifestid\s*\("#, $0).isEmpty
        }
        var result = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        if let manifests {
            for (id, gid) in manifests.sorted(by: { $0.key < $1.key }) where UInt64(gid) != nil {
                result += "setManifestid(\(id), \"\(gid)\", 0)\n"
            }
        }
        return try .parse(result, suggestedID: appID)
    }
}
