import Foundation

/// Steam's public schema contains definitions, never the player's unlock state.
public struct OfflineSchema: Sendable {
    public struct Definition: Sendable {
        public let name: String, displayName: String, description: String
        public let hidden: Int
        public let icon: String, iconGray: String
    }
    public let definitions: [Definition]
    public var images: [String: Data] = [:]

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let game = root["game"] as? [String: Any],
              let stats = game["availableGameStats"] as? [String: Any] else {
            throw AppFailure("未返回有效成就架构 / No valid achievement schema returned")
        }
        guard stats["achievements"] == nil || stats["achievements"] is [[String: Any]] else { throw AppFailure("成就列表格式无效 / Invalid achievement list") }
        let rows = stats["achievements"] as? [[String: Any]] ?? []
        guard rows.count <= 10000 else { throw AppFailure("成就数量超过限制 / Achievement count limit exceeded") }
        var seen = Set<String>()
        let definitions = try rows.map { row -> Definition in
            guard let name = row["name"] as? String, !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0"), seen.insert(name).inserted else { throw AppFailure("成就标识无效或重复 / Invalid or duplicate achievement identifier") }
            return Definition(name: name, displayName: row["displayName"] as? String ?? name, description: row["description"] as? String ?? "", hidden: (row["hidden"] as? Int ?? 0) == 0 ? 0 : 1, icon: row["icon"] as? String ?? "", iconGray: row["icongray"] as? String ?? "")
        }
        return Self(definitions: definitions)
    }
    public static func fetch(appID: Int, apiKey: String, language: String, withImages: Bool) async throws -> Self {
        guard TextUtil.validID(String(appID)) != nil, apiKey.count == 32, apiKey.allSatisfy({ $0.isASCII && $0.isHexDigit }), ["english", "schinese"].contains(language) else { throw AppFailure("AppID、语言或 Web API Key 格式无效 / Invalid AppID, language or Web API key") }
        do {
            let url = try HTTP.url("https://api.steampowered.com/ISteamUserStats/GetSchemaForGame/v2/", query: ["appid": String(appID), "key": apiKey, "l": language])
            var schema = try parse(await HTTP.get(url, limit: 16 * 1024 * 1024))
            if withImages {
                var total = 0
                for raw in Set(schema.definitions.flatMap { [$0.icon, $0.iconGray] }).sorted() where !raw.isEmpty {
                    try Task.checkCancellation()
                    guard let url = imageURL(raw), let path = imagePath(raw) else { throw AppFailure("成就图标不是 Steam HTTPS 资源 / Achievement icon is not a Steam HTTPS resource") }
                    let bytes = try await HTTP.get(url, limit: 4 * 1024 * 1024)
                    total += bytes.count
                    guard total <= 64 * 1024 * 1024 else { throw AppFailure("成就图片总大小超过限制 / Achievement images exceed the size limit") }
                    schema.images[path] = bytes
                }
            }
            return schema
        } catch { throw AppFailure(error.localizedDescription.replacingOccurrences(of: apiKey, with: "<redacted>")) }
    }
    public static func imageURL(_ raw: String) -> URL? {
        guard var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme), let host = c.host?.lowercased(), c.user == nil, c.password == nil, c.port == nil,
              ["steamstatic.com", "steamcommunity.com", "akamaihd.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        c.scheme = "https"; return c.url
    }
    public static func imagePath(_ raw: String) -> String? {
        guard let url = imageURL(raw) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard ["jpg", "jpeg", "png"].contains(ext) else { return nil }
        return "achievement_images/" + FileStore.hash(Data(url.absoluteString.utf8)) + "." + ext
    }
    public func json() throws -> Data {
        let rows: [[String: Any]] = definitions.map { item in
            var row: [String: Any] = ["name": item.name, "displayName": item.displayName, "description": item.description, "hidden": item.hidden]
            if let path = Self.imagePath(item.icon), images[path] != nil { row["icon"] = path }
            if let path = Self.imagePath(item.iconGray), images[path] != nil { row["icon_gray"] = path }
            return row
        }
        return try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    }
}
