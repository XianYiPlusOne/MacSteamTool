import Foundation

/// Verifies the compatibility backend's persisted state. A rejected Valve
/// StoreStats callback is never renamed to success without this independent
/// account/app-scoped disk check and a fresh native API read.
public enum CompatibilityAchievements {
    public static func active(root: URL, appID: Int, runningPIDs: [Int32] = SteamProcesses.pids()) -> Bool {
        guard let config = try? FileStore.read(root.appendingPathComponent("CloudRedirect/config.json")),
              let c = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              c["sync_achievements"] as? Bool == true, (c["stats_apps"] as? [Int] ?? []).contains(appID),
              let status = try? FileStore.read(root.appendingPathComponent("CloudRedirect/runtime-status.json")),
              let s = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              let pid = s["pid"] as? Int32, runningPIDs.contains(pid), s["cloudReady"] as? Bool == true,
              s["cloudConfigSHA256"] as? String == FileStore.hash(config) else { return false }
        return true
    }
    public static func verify(root: URL, account: UInt32, appID: Int, rows: [Achievement], changes: [AchievementChange]) throws {
        guard account != 0, !changes.isEmpty else { throw AppFailure("Invalid compatibility verification context") }
        let folder = root.appendingPathComponent("CloudRedirect/stats/\(account)")
        let schema = try FileStore.read(folder.appendingPathComponent("schemas/\(appID).bin"))
        var parser = SchemaParser(bytes: Array(schema))
        let tree = try parser.read(depth: 0)
        guard let stats = tree[String(appID)]?.children?["stats"]?.children else { throw AppFailure("Compatibility schema does not match this game") }
        var mapping: [String: (Int, Int)] = [:]
        for (statID, node) in stats {
            guard let id = Int(statID), let bits = node.children?["bits"]?.children else { continue }
            for (key, bit) in bits {
                guard let index = Int(key), (0..<32).contains(index), let name = bit.children?["name"]?.text, !name.isEmpty,
                      mapping.updateValue((id, index), forKey: name) == nil else { throw AppFailure("Invalid achievement schema mapping") }
            }
        }
        guard let record = try JSONSerialization.jsonObject(with: FileStore.read(folder.appendingPathComponent("\(appID).json"))) as? [String: Any],
              let blocks = record["achievements"] as? [[String: Any]], let statsRows = record["stats"] as? [[String: Any]] else { throw AppFailure("Compatibility statistics were not persisted") }
        for change in changes {
            guard let (stat, bit) = mapping[change.id], let row = rows.first(where: { $0.id == change.id }), row.achieved == change.achieved,
                  let block = blocks.first(where: { $0["stat_id"] as? Int == stat }), let mask = block["bits"] as? UInt32,
                  let times = block["unlock_times"] as? [UInt32], times.count == 32,
                  let value = statsRows.first(where: { $0["id"] as? Int == stat })?["value"] as? UInt32,
                  (mask & (1 << bit) != 0) == change.achieved, (value & (1 << bit) != 0) == change.achieved,
                  // Steam stamps the local API unlock before sending it; the
                  // compatibility observer stamps receipt. The API edit only
                  // changes the boolean, so these clocks need not be identical.
                  (change.achieved ? (times[bit] > 0 && row.unlockedAt > 0) : (times[bit] == 0 && row.unlockedAt == 0)) else { throw AppFailure("Compatibility write could not be verified for \(change.id); reload before editing") }
        }
    }
    private struct Node { var text: String?; var children: [String: Node]? }
    private struct SchemaParser {
        let bytes: [UInt8]; var offset = 0; var nodes = 0
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset <= bytes.count - n else { throw AppFailure("Truncated achievement schema") }
            defer { offset += n }; return Array(bytes[offset..<offset+n])
        }
        mutating func string() throws -> String {
            let start = offset
            while offset < bytes.count && bytes[offset] != 0 && offset - start <= 65536 { offset += 1 }
            guard offset < bytes.count, offset - start <= 65536, let value = String(bytes: bytes[start..<offset], encoding: .utf8) else { throw AppFailure("Invalid achievement schema string") }
            offset += 1; return value
        }
        mutating func read(depth: Int) throws -> [String: Node] {
            guard depth <= 32, bytes.count <= 16 * 1024 * 1024 else { throw AppFailure("Achievement schema exceeds limits") }
            var result: [String: Node] = [:]
            while offset < bytes.count {
                let type = try take(1)[0]; if type == 8 { return result }
                nodes += 1; guard nodes <= 200000 else { throw AppFailure("Achievement schema exceeds limits") }
                let key = try string(); var node = Node()
                switch type {
                case 0: node.children = try read(depth: depth + 1)
                case 1: node.text = try string()
                case 2, 3, 4, 6: _ = try take(4)
                case 7: _ = try take(8)
                case 10: _ = try take(8)
                default: throw AppFailure("Unsupported achievement schema value")
                }
                guard result.updateValue(node, forKey: key) == nil else { throw AppFailure("Duplicate achievement schema key") }
            }
            throw AppFailure("Unterminated achievement schema")
        }
    }
}
