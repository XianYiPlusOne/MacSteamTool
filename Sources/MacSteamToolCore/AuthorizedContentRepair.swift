import Foundation

/// Validates a signed-in extraction response before preparing any library writes.
public enum AuthorizedContentRepair {
    public static func missingDepots(in warnings: [String]) -> Set<Int> {
        Set(warnings.filter { $0.contains("Missing depot key") }.flatMap {
            TextUtil.matches(#"Depot (\d+)"#, $0).compactMap { Int($0[1]) }
        })
    }

    public static func prepare(document: LuaDocument, missing: Set<Int>, response: SteamEngineResponse) throws -> ImportFile {
        guard response.ok, response.appID == document.appID, !missing.isEmpty else {
            throw AppFailure("授权提取结果不匹配 / Authorized extraction result mismatch")
        }
        let owners = Set([document.appID] + document.dlcIDs)
        var selected: [OwnedDepot] = []
        for id in missing.sorted() {
            let matches = (response.depots ?? []).filter { $0.id == id }
            guard matches.count == 1, let depot = matches.first else {
                throw AppFailure("Depot \(id)：Steam 未返回唯一的授权提取结果 / Steam returned no unique extraction result")
            }
            guard depot.result == "OK", TextUtil.validKey(depot.key), owners.contains(depot.owner) else {
                throw AppFailure("Depot \(id)：\(TextUtil.cleanLine(depot.result))；未修改入库配置 / Library unchanged")
            }
            if let old = document.depots.first(where: { $0.id == id })?.key, old.lowercased() != depot.key.lowercased() {
                throw AppFailure("Depot \(id) 与现有密钥冲突，未修改 / Key conflicts with existing content; unchanged")
            }
            selected.append(depot)
        }
        var text = document.raw.trimmingCharacters(in: .newlines) + "\n"
        for owner in Set(selected.map(\.owner)).sorted() {
            // Explicit owner boundaries preserve Lua ownership even after DLC blocks.
            text += "\n-- Authorized Steam content repair\naddappid(\(owner))\n"
            for depot in selected.filter({ $0.owner == owner }).sorted(by: { $0.id < $1.id }) {
                if !document.depots.contains(where: { $0.id == depot.id }) {
                    text += "addappid(\(depot.id), 1, \"\(depot.key.lowercased())\")\n"
                }
            }
        }
        // Do not introduce version pins: Steam selects the current published manifest.
        _ = try LuaDocument.parse(text, suggestedID: document.appID)
        return ImportFile(name: "\(document.appID).lua", data: Data(text.utf8))
    }
}
