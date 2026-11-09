import Foundation
import Security

public enum SecretStore {
    private static func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.fluentsteam.mac.sources", kSecAttrAccount as String: account] }
    public static func load(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true
        var result: CFTypeRef?; let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw AppFailure("Keychain: \(code)") }; return data
    }
    public static func save(_ data: Data?, account: String) throws {
        if let data {
            let update = [kSecValueData as String: data]
            var code = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
            if code == errSecItemNotFound {
                var q = query(account); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                code = SecItemAdd(q as CFDictionary, nil)
            }
            guard code == errSecSuccess else { throw AppFailure("Keychain: \(code)") }
        } else {
            let code = SecItemDelete(query(account) as CFDictionary)
            guard code == errSecSuccess || code == errSecItemNotFound else { throw AppFailure("Keychain: \(code)") }
        }
    }
}
public struct ManifestHubCredential: Codable, Sendable {
    public var key: String
    public var saved: Date
    public var expiry: Date { saved.addingTimeInterval(86400) }
    public static func load() throws -> Self? { try SecretStore.load("manifesthub").map { try JSONDecoder().decode(Self.self, from: $0) } }
    public static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, !key.contains(where: \.isNewline) else { throw AppFailure("API Key 无效 / Invalid API key") }
        try SecretStore.save(JSONEncoder().encode(Self(key: key, saved: Date())), account: "manifesthub")
    }
    public static func remove() throws { try SecretStore.save(nil, account: "manifesthub") }
}
public enum ManifestHubFailure: LocalizedError {
    case expiredKey, rejectedKey, notFound
    public var errorDescription: String? {
        switch self {
        case .expiredKey: return "ManifestHub Key 本地有效期已过，请重新保存 / ManifestHub key expired locally; save a new key"
        case .rejectedKey: return "ManifestHub 拒绝了 Key，请重新填写 / ManifestHub rejected the key; enter a new key"
        case .notFound: return "ManifestHub 没有该清单 / ManifestHub has no matching manifest"
        }
    }
    public var stopsMonitor: Bool { switch self { case .expiredKey, .rejectedKey: true; case .notFound: false } }
}
public enum ManifestHub {
    public static func fetch(depot: Int, manifest: String, credential: ManifestHubCredential, now: Date = Date(), download: @Sendable (URL) async throws -> Data = { try await HTTP.get($0, timeout: 45) }, delay: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> Data {
        guard credential.expiry > now else { throw ManifestHubFailure.expiredKey }
        guard TextUtil.validID(String(depot)) != nil, let gid = UInt64(manifest), gid > 0 else { throw AppFailure("无效 DepotID / ManifestID") }
        let url = try HTTP.url("https://api.manifesthub2.filegear-sg.me/manifest", query: ["apikey": credential.key, "depotid": String(depot), "manifestid": manifest])
        for attempt in 0...3 {
            do {
                let data = try await download(url)
                try SteamManifest.validate(data, depot: depot, manifest: manifest); return data
            } catch let error as HTTPStatusFailure {
                if error.status == 401 || error.status == 403 { throw ManifestHubFailure.rejectedKey }
                if error.status == 400 || error.status == 404 { throw ManifestHubFailure.notFound }
                guard attempt < 3, [429, 500, 502, 503, 504].contains(error.status) else { throw AppFailure("ManifestHub HTTP \(error.status)") }
                try await delay(error.retryAfter ?? [2.0, 5, 10][attempt])
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < 3 else { throw AppFailure("ManifestHub 网络失败 / Network failure (\(error.code.rawValue))") }
                try await delay([2.0, 5, 10][attempt])
            }
        }
        throw AppFailure("ManifestHub 下载失败 / Download failed")
    }
}
public enum RemoteLuaPackage {
    public static let defaultTemplate = "https://steamgames554.s3.us-east-1.amazonaws.com/{app}.zip"
    public static func source(_ preferences: Preferences) throws -> (template: String, linked: Bool) {
        let linked = preferences.remotePackageMode != "direct"
        let value = linked ? defaultTemplate : (preferences.remotePackageURL ?? defaultTemplate).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("{app}"), let url = URLComponents(string: value.replacingOccurrences(of: "{app}", with: "480")),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw AppFailure("远程包地址需要 HTTPS 和 {app} / Remote package URL requires HTTPS and {app}") }
        return (value, linked)
    }
    public static func fetch(appID: Int, preferences: Preferences, engine: URL) async throws -> [ImportFile] {
        let source = try source(preferences)
        return try await fetch(appID: appID, template: source.template, engine: engine, useLinkService: source.linked)
    }
    public static func fetch(appID: Int, template: String, engine: URL, useLinkService: Bool = false) async throws -> [ImportFile] {
        guard TextUtil.validID(String(appID)) != nil, template.contains("{app}") else { throw AppFailure("远程包 URL 需要 {app} / Remote package URL requires {app}") }
        let url = try HTTP.url(template.replacingOccurrences(of: "{app}", with: String(appID)))
        let downloadURL: URL
        if useLinkService {
            let link = try await HTTP.form(HTTP.url("https://short.walftech.com/api_create_link.php"), fields: ["url": url.absoluteString], headers: ["Origin": "https://remlua.com", "Referer": "https://remlua.com/"])
            downloadURL = try proxyURL(link)
        } else { downloadURL = url }
        let data = try await HTTP.get(downloadURL, limit: 64 * 1024 * 1024, headers: useLinkService ? ["Referer": "https://short.walftech.com/"] : [:])
        return try await extract(data, appID: appID, engine: engine)
    }
    public static func proxyURL(_ response: Data) throws -> URL {
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any], let code = json["short_code"] as? String,
              (1...128).contains(code.utf8.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }) else { throw AppFailure("远程仓库未返回有效链接代码 / Remote repository returned no valid link code") }
        return try HTTP.url("https://short.walftech.com/proxy.php", query: ["short": code])
    }
    public static func extract(_ data: Data, appID: Int, engine: URL) async throws -> [ImportFile] {
        guard TextUtil.validID(String(appID)) != nil, data.count <= 64 * 1024 * 1024 else { throw AppFailure("无效远程包 / Invalid remote package") }
        guard data.starts(with: [0x50, 0x4b]) else { throw AppFailure("远程仓库未返回 ZIP / Remote repository did not return a ZIP") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FluentRemote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appendingPathComponent("\(appID).zip"); try FileStore.write(data, to: zip)
        let files = try await ArchiveIO.importFiles([zip], engine: engine)
        let lua = try files.filter { $0.name.lowercased().hasSuffix(".lua") }.map { file -> ImportFile in
            let doc = try LuaDocument.parse(String(decoding: file.data, as: UTF8.self), suggestedID: TextUtil.validID(URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent))
            guard doc.appID == appID else { throw AppFailure("远程包包含其他游戏 Lua / Remote package contains a different game's Lua") }
            return file
        }
        guard !lua.isEmpty else { throw AppFailure("远程包没有 Lua / Remote package has no Lua") }; return lua
    }
}

public enum DiscoveryCharts {
    public static func load() async throws -> [GameMetadata] {
        var games: [GameMetadata] = [], seen = Set<Int>()
        for offset in [0, 30, 60, 90] {
            let root = try await HTTP.json(HTTP.url("https://api.xiaoheihe.cn/game/web/all_recommend/games/", query: ["os_type": "web", "version": "999.0.0", "show_type": "popular", "limit": "30", "offset": String(offset)]))
            guard let result = root["result"] as? [String: Any], let list = result["list"] as? [[String: Any]] else { throw AppFailure("榜单格式已变化 / Chart format changed") }
            for row in list {
                guard let value = row["appid"], let id = TextUtil.validID(String(describing: value)), seen.insert(id).inserted,
                      let name = (row["game_name"] ?? row["name"]) as? String, !name.isEmpty else { continue }
                games.append(GameMetadata(id: id, name: name, image: row["game_img"] as? String ?? ""))
            }
        }
        guard !games.isEmpty else { throw AppFailure("榜单暂时没有内容 / Charts are empty") }; return games
    }
}
extension TrainerSearch {
    public static func chart(_ kind: String) async throws -> [WebDownload] {
        let html = String(decoding: try await HTTP.get(HTTP.url("https://flingtrainer.com/"), limit: 8 * 1024 * 1024), as: UTF8.self)
        return parseChart(html, kind: kind)
    }
    public static func parseChart(_ html: String, kind: String) -> [WebDownload] {
        let pattern = kind == "popular"
            ? #"(?is)<a\b(?=[^>]*class=["'][^"']*\bwpp-post-title\b)[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
            : #"(?is)<h3[^>]*class=["'][^"']*\brpwe-title\b[^"']*["'][^>]*>\s*<a[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        var seen = Set<String>()
        return Array(TextUtil.matches(pattern, html).compactMap { match -> WebDownload? in
            guard let url = URL(string: match[1]), url.scheme == "https", url.host == "flingtrainer.com", seen.insert(url.absoluteString).inserted else { return nil }
            let name = match[2].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&#8217;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
            return WebDownload(title: name, url: url)
        }.prefix(10))
    }
}
