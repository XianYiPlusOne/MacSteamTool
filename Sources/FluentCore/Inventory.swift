import Foundation

public struct OfflineInventory: Sendable {
    public let items: [String: [String: String]]
    public let quantities: [String: Int]
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw AppFailure("物品定义过大 / Item definitions too large") }
        let trimmed = data.prefix { $0 != 0 }
        let json = try JSONSerialization.jsonObject(with: trimmed)
        let records: [[String: Any]]
        if let array = json as? [[String: Any]] { records = array }
        else if let dictionary = json as? [String: [String: Any]] {
            records = try dictionary.map { id, item in
                var record = item
                if let value = item["itemdefid"], String(describing: value) != id { throw AppFailure("物品 ID 不匹配 / Item ID mismatch") }
                record["itemdefid"] = id; return record
            }
        } else { throw AppFailure("物品定义必须为数组或 ID 字典 / Expected item array or ID dictionary") }
        guard records.count <= 50000 else { throw AppFailure("物品数量超过限制 / Item count limit exceeded") }
        var items: [String: [String: String]] = [:]
        for record in records {
            guard let raw = record["itemdefid"], let id = TextUtil.validID(String(describing: raw)), items[String(id)] == nil else { throw AppFailure("物品 ID 无效或重复 / Invalid or duplicate item ID") }
            var item: [String: String] = [:]
            for (key, value) in record where !(value is NSNull) {
                if let value = value as? String { item[key] = value }
                else if let value = value as? NSNumber { item[key] = value.stringValue }
                else { item[key] = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self) }
            }
            items[String(id)] = item
        }
        return Self(items: items, quantities: Dictionary(uniqueKeysWithValues: items.keys.map { ($0, 1) }))
    }
    public static func fetch(appID: Int, apiKey: String = "") async throws -> Self {
        guard TextUtil.validID(String(appID)) != nil, apiKey.isEmpty || (apiKey.count == 32 && apiKey.allSatisfy({ $0.isASCII && $0.isHexDigit })) else { throw AppFailure("AppID 或 Web API Key 格式无效 / Invalid AppID or Web API key") }
        var query = ["appid": String(appID)]; if !apiKey.isEmpty { query["key"] = apiKey }
        do {
            let result = try await HTTP.json(HTTP.url("https://api.steampowered.com/IInventoryService/GetItemDefMeta/v1/", query: query))
            guard let response = result["response"] as? [String: Any], let digest = response["digest"] as? String, !digest.isEmpty, digest.count <= 256 else { throw AppFailure("此游戏没有返回物品定义摘要 / No item-definition digest returned") }
            let bytes = try await HTTP.get(HTTP.url("https://api.steampowered.com/IGameInventory/GetItemDefArchive/v0001/", query: ["appid": String(appID), "digest": digest]), limit: 16 * 1024 * 1024)
            return try parse(bytes)
        } catch { throw AppFailure(apiKey.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: apiKey, with: "<redacted>")) }
    }
}
