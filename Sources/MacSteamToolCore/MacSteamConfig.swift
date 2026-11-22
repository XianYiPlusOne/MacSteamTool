import Foundation

/// macSteam's documented YAML subset, with unknown top-level sections preserved.
/// Format interoperability informed by crghofficial/macsteam (AGPL-3.0).
public struct MacSteamConfig: Sendable {
    public var apps: [Int] = []
    public var packages: [Int] = []
    public var keys: [Int: [Int: String]] = [:]
    public var names: [Int: String] = [:]
    public var parents: [Int: Int] = [:]
    public var manifestPins: [Int: [Int: String]] = [:]
    public var accessTokens: [Int: String] = [:]
    public var hideWhatsNew = false
    public var unknown: [String] = []
    public init() {}
    public var topLevel: [Int] { apps.filter { parents[$0] == nil } }
    public func children(_ id: Int) -> [Int] { apps.filter { parents[$0] == id } }
    public static func parse(_ text: String) throws -> Self {
        var c = Self(); var section = ""; var owner: Int?
        var unknownBlock: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !t.isEmpty && !t.hasPrefix("#") {
                if !unknownBlock.isEmpty { c.unknown.append(unknownBlock.joined(separator: "\n")); unknownBlock = [] }
                section = String(t.prefix { $0 != ":" }); owner = nil
                if section == "HideWhatsNew" {
                    let v = t.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                    c.hideWhatsNew = ["yes", "true", "1"].contains(v)
                } else if !["Apps", "PackageIds", "DepotKeys", "FluentManifestPins", "FluentAccessTokens"].contains(section) { unknownBlock.append(line) }
                else if t != section + ":" { throw AppFailure("不支持内联 YAML / Inline YAML is unsupported：\(section)。请先在 macSteam Config 中保存配置 / Save the configuration in macSteam Config first") }
                continue
            }
            if !["Apps", "PackageIds", "DepotKeys", "HideWhatsNew", "FluentManifestPins", "FluentAccessTokens"].contains(section) { unknownBlock.append(line); continue }
            if t.isEmpty || t.hasPrefix("#") { continue }
            if section == "Apps" || section == "PackageIds" {
                guard let m = TextUtil.matches(#"^  -\s+(\d+)(?:\s*#\s*(.*))?\s*$"#, line).first,
                      let id = TextUtil.validID(m[1]) else { throw AppFailure("配置格式异常 / Invalid configuration format：\(section)；为避免丢失数据，已取消写入 / Write cancelled to preserve existing data") }
                if section == "PackageIds" { if !c.packages.contains(id) { c.packages.append(id) }; continue }
                if !c.apps.contains(id) { c.apps.append(id) }
                if let p = TextUtil.matches(#"@(\d+)"#, m[2]).first, let parent = TextUtil.validID(p[1]) { c.parents[id] = parent }
                c.names[id] = m[2].replacingOccurrences(of: #"@\d+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            } else if section == "FluentAccessTokens" {
                guard let m = TextUtil.matches(#"^  (\d+):\s*(\d+)\s*(?:#.*)?$"#, line).first,
                      let id = TextUtil.validID(m[1]), let token = UInt64(m[2]), token > 0,
                      c.accessTokens[id] == nil, c.accessTokens.count < 4096 else { throw AppFailure("访问令牌配置无效或重复 / Invalid or duplicate access token configuration") }
                c.accessTokens[id] = String(token)
            } else if section == "FluentManifestPins" {
                if let m = TextUtil.matches(#"^  (\d+):\s*$"#, line).first, let id = TextUtil.validID(m[1]) { owner = id }
                else if let owner, let m = TextUtil.matches(#"^    (\d+):\s*(\d+)\s*(?:#.*)?$"#, line).first,
                        let id = TextUtil.validID(m[1]), let gid = UInt64(m[2]), gid > 0, c.manifestPins[owner]?[id] == nil {
                    c.manifestPins[owner, default: [:]][id] = String(gid)
                } else { throw AppFailure("无法解析 FluentManifestPins；未覆盖现有版本锁定 / Cannot parse FluentManifestPins; existing pins preserved") }
            } else if section == "DepotKeys" {
                if let m = TextUtil.matches(#"^  (\d+):\s*$"#, line).first, let id = TextUtil.validID(m[1]) { owner = id; c.keys[id] = c.keys[id] ?? [:] }
                else if let owner, let m = TextUtil.matches(#"^    (\d+):\s*['"]?([0-9a-fA-F]{64})['"]?\s*(?:#.*)?$"#, line).first,
                        let id = TextUtil.validID(m[1]) { c.keys[owner, default: [:]][id] = m[2].lowercased() }
                else { throw AppFailure("无法解析 DepotKeys；为避免覆盖现有密钥，已取消写入 / Cannot parse DepotKeys; write cancelled to preserve existing keys") }
            }
        }
        if !unknownBlock.isEmpty { c.unknown.append(unknownBlock.joined(separator: "\n")) }
        try c.validatePins()
        return c
    }
    public mutating func merge(_ document: LuaDocument, name: String? = nil) throws {
        let main = document.appID
        let appIDs = [main] + document.dlcIDs
        for id in appIDs {
            accessTokens[id] = document.tokens[id].flatMap { UInt64($0).flatMap { $0 > 0 ? String($0) : nil } }
            if !apps.contains(id) { apps.append(id) }
            if id != main {
                if let p = parents[id], p != main { throw AppFailure("DLC \(id) 已属于 / already belongs to \(p)，请先解决配置冲突 / Resolve the configuration conflict first") }
                parents[id] = main
            }
        }
        for entry in document.entries {
            if let key = entry.key { keys[entry.owner, default: [:]][entry.id] = key }
            else if !entry.name.isEmpty { names[entry.id] = entry.name }
        }
        if !document.name.isEmpty { names[main] = document.name }
        if let name, !name.isEmpty { names[main] = name }
        var pins: [Int: String] = [:]
        for pin in document.pins where pin.active {
            guard let gid = UInt64(pin.manifest), gid > 0, pins[pin.depot] == nil else { throw AppFailure("重复或无效的 Manifest 版本声明 / Duplicate or invalid manifest version declaration") }
            pins[pin.depot] = String(gid)
        }
        manifestPins[main] = pins.isEmpty ? nil : pins
        if packages.isEmpty { packages = [20200] }
        try validate()
    }
    public mutating func remove(_ id: Int) {
        var removed: Set<Int> = [id]
        while true {
            let next = removed.union(parents.filter { removed.contains($0.value) }.keys)
            if next == removed { break }; removed = next
        }
        apps.removeAll { removed.contains($0) }
        for id in removed { keys[id] = nil; names[id] = nil; parents[id] = nil; manifestPins[id] = nil; accessTokens[id] = nil }
    }
    public func validate() throws {
        try validatePins()
        guard accessTokens.count <= 4096, accessTokens.allSatisfy({ TextUtil.validID(String($0.key)) != nil && (UInt64($0.value) ?? 0) > 0 }) else { throw AppFailure("访问令牌无效或超过限制 / Invalid access tokens or too many entries") }
        guard keys.count <= 256, keys.values.allSatisfy({ $0.count <= 64 }) else {
            throw AppFailure("超出 macSteam 0.8.2 内核容量（256 个密钥组，每组 64 个 depot）；未写入 / macSteam 0.8.2 limit exceeded: 256 key groups, 64 depots each; nothing written")
        }
    }
    private func validatePins() throws {
        var depots = Set<Int>()
        for pins in manifestPins.values {
            for (depot, gid) in pins {
                guard TextUtil.validID(String(depot)) != nil, let value = UInt64(gid), value > 0, depots.insert(depot).inserted, depots.count <= 4096 else {
                    throw AppFailure("Manifest 锁定有重复 Depot、无效版本或超过 4096 项；未写入 / Manifest pins contain duplicates, invalid versions or over 4096 entries; nothing written")
                }
            }
        }
    }
    public func serialized() -> String {
        var s = "HideWhatsNew: \(hideWhatsNew ? "yes" : "no")\n\n"
        if !apps.isEmpty {
            s += "Apps:\n"
            for id in apps {
                var comment = TextUtil.cleanLine(names[id] ?? "")
                if let p = parents[id] { comment += " @\(p)" }
                s += "  - \(id)" + (comment.isEmpty ? "" : "  # \(comment)") + "\n"
            }
        }
        if !packages.isEmpty { s += "\nPackageIds:\n" + packages.map { "  - \($0)\n" }.joined() }
        if !keys.isEmpty {
            s += "\nDepotKeys:\n"
            for (app, depots) in keys.sorted(by: { $0.key < $1.key }) {
                s += "  \(app):\n"
                for (depot, key) in depots.sorted(by: { $0.key < $1.key }) { s += "    \(depot): \(key)\n" }
            }
        }
        if !manifestPins.isEmpty {
            s += "\nFluentManifestPins:\n"
            for (app, pins) in manifestPins.sorted(by: { $0.key < $1.key }) {
                s += "  \(app):\n"
                for (depot, gid) in pins.sorted(by: { $0.key < $1.key }) { s += "    \(depot): \(gid)\n" }
            }
        }
        if !accessTokens.isEmpty {
            s += "\nFluentAccessTokens:\n"
            for (app, token) in accessTokens.sorted(by: { $0.key < $1.key }) { s += "  \(app): \(token)\n" }
        }
        if !unknown.isEmpty { s += "\n" + unknown.joined(separator: "\n") }
        return s.trimmingCharacters(in: .newlines) + "\n"
    }
    public func lua(for id: Int) -> String {
        var text = "-- Exported from macSteam by MacSteamTool\naddappid(\(id)) -- \(TextUtil.cleanLine(names[id] ?? ""))\n"
        for owner in [id] + children(id) {
            if owner != id { text += "\naddappid(\(owner)) -- \(TextUtil.cleanLine(names[owner] ?? ""))\n" }
            if let token = accessTokens[owner] { text += "addtoken(\(owner), \"\(token)\")\n" }
            for (depot, key) in (keys[owner] ?? [:]).sorted(by: { $0.key < $1.key }) {
                text += "addappid(\(depot), 1, \"\(key)\")\n"
            }
            for (depot, gid) in (manifestPins[owner] ?? [:]).sorted(by: { $0.key < $1.key }) { text += "setManifestid(\(depot), \"\(gid)\", 0)\n" }
        }
        return text
    }
}
