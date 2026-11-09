import Foundation
import ZIPFoundation

public struct HTTPStatusFailure: LocalizedError {
    public let status: Int
    public let retryAfter: Double?
    public var errorDescription: String? { "HTTP \(status)" }
}
private final class SourceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let sensitive = task.originalRequest?.url?.query?.contains("apikey=") == true || task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil
        let allowed = request.url?.scheme == "https" && (!sensitive || request.url?.host == task.originalRequest?.url?.host)
        completionHandler(allowed ? request : nil)
    }
}
public enum HTTP {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25; cfg.timeoutIntervalForResource = 120
        cfg.httpCookieStorage = nil; cfg.httpShouldSetCookies = false
        cfg.httpAdditionalHeaders = ["User-Agent": "FluentSteamMac/0.1 (+https://github.com/huanyuejue/Fluent-Steam-Lua)"]
        return URLSession(configuration: cfg, delegate: SourceRedirects(), delegateQueue: nil)
    }()
    public static func get(_ url: URL, limit: Int = 64 * 1024 * 1024, headers: [String: String] = [:], timeout: TimeInterval = 25) async throws -> Data {
        guard url.scheme == "https" else { throw AppFailure("数据源必须使用 HTTPS / Data source must use HTTPS") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, limit: limit)
    }
    public static func form(_ url: URL, fields: [String: String], headers: [String: String] = [:]) async throws -> Data {
        guard url.scheme == "https" else { throw AppFailure("Data source must use HTTPS") }
        var encoded = URLComponents(); encoded.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url, timeoutInterval: 30); request.httpMethod = "POST"
        request.httpBody = Data((encoded.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, limit: 1024 * 1024)
    }
    private static func send(_ request: URLRequest, limit: Int) async throws -> Data {
        let (temp, response) = try await session.download(for: request)
        defer { try? FileStore.fm.removeItem(at: temp) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let http = response as? HTTPURLResponse
            let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { min(30, max(1, $0)) }
            throw HTTPStatusFailure(status: http?.statusCode ?? 0, retryAfter: retry)
        }
        guard response.url?.scheme == "https" else { throw AppFailure("数据源重定向到了不安全连接 / Data source redirected to an insecure connection") }
        let size = (try FileStore.fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= limit else { throw AppFailure("下载超过限制 / Download exceeds \(limit / 1024 / 1024) MB") }
        return try Data(contentsOf: temp)
    }
    public static func json(_ url: URL) async throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: await get(url)) as? [String: Any] else { throw AppFailure("服务器未返回有效 JSON / Server did not return valid JSON") }; return dict
    }
    public static func url(_ base: String, query: [String: String] = [:]) throws -> URL {
        guard var c = URLComponents(string: base) else { throw AppFailure("无效的 URL / Invalid URL") }
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw AppFailure("无效的 URL / Invalid URL") }; return url
    }
}

public actor SteamAPI {
    public let cache: URL
    public init(cache: URL) { self.cache = cache }
    public func search(_ query: String, language: String = "schinese") async throws -> [GameMetadata] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = TextUtil.validID(q) { return [try await details(id, language: language)] }
        let data = try await HTTP.json(HTTP.url("https://store.steampowered.com/api/storesearch/", query: ["term": q, "l": language, "cc": "cn"]))
        return (data["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            let p = item["platforms"] as? [String: Bool] ?? [:]
            return GameMetadata(id: id, name: name, image: item["tiny_image"] as? String ?? "", mac: p["mac"] ?? false, windows: p["windows"] ?? false)
        }
    }
    public func details(_ id: Int, language: String = "schinese", refresh: Bool = false) async throws -> GameMetadata {
        let file = cache.appendingPathComponent("\(language)-\(id).json")
        if !refresh, let saved = try? FileStore.decode(GameMetadata.self, at: file) { return saved }
        let root = try await HTTP.json(HTTP.url("https://store.steampowered.com/api/appdetails", query: ["appids": String(id), "l": language, "cc": "cn"]))
        guard let item = root[String(id)] as? [String: Any], item["success"] as? Bool == true,
              let data = item["data"] as? [String: Any], let name = data["name"] as? String else { throw AppFailure("Steam 商店未返回 AppID / Steam Store did not return AppID \(id)，可能已下架或所在地区不可用 / It may be delisted or unavailable in this region") }
        let platforms = data["platforms"] as? [String: Bool] ?? [:]
        let game = GameMetadata(id: id, name: name, image: data["header_image"] as? String ?? "", description: (data["short_description"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), mac: platforms["mac"] ?? false, windows: platforms["windows"] ?? false, dlc: data["dlc"] as? [Int] ?? [])
        try FileStore.json(game, to: file)
        return game
    }
    public func cached(language: String = "schinese") -> [Int: GameMetadata] {
        var items: [Int: GameMetadata] = [:]
        for file in FileStore.files(cache) where file.lastPathComponent.hasPrefix(language + "-") {
            if let data = try? FileStore.decode(GameMetadata.self, at: file) { items[data.id] = data }
        }
        return items
    }
    public func appInfo(_ id: Int) async throws -> AppInfo {
        let root = try await HTTP.json(HTTP.url("https://api.steamcmd.net/v1/info/\(id)"))
        guard let data = root["data"] as? [String: Any], let app = data[String(id)] as? [String: Any] else { throw AppFailure("未取得 AppID / Could not retrieve depot data for AppID \(id) 的 depot 数据 / depot data") }
        let info = AppInfo(id: id, dictionary: app)
        try FileStore.json(info, to: cache.appendingPathComponent("appinfo-\(id).json"))
        return info
    }
    public func compatibilityInfo(_ id: Int) async throws -> AppInfo {
        let file = cache.appendingPathComponent("appinfo-\(id).json")
        if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < 86400,
           let info = try? FileStore.decode(AppInfo.self, at: file), info.id == id { return info }
        return try await appInfo(id)
    }
}

public struct Depot: Identifiable, Codable, Sendable {
    public var id: Int
    public var manifest: String
    public var os: String
    public var dlc: Int?
}
public struct AppInfo: Codable, Sendable {
    public var id: Int
    public var name: String
    public var depots: [Depot]
    public var dlc: [Int]
    public var platforms: Set<String>
    public init(id: Int, dictionary app: [String: Any]) {
        self.id = id; name = (app["common"] as? [String: Any])?["name"] as? String ?? "App \(id)"
        platforms = Set(((app["common"] as? [String: Any])?["oslist"] as? String ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        depots = []; dlc = []
        let extended = app["extended"] as? [String: Any] ?? [:]
        if let list = extended["listofdlc"] as? String { dlc = list.split(separator: ",").compactMap { TextUtil.validID($0.trimmingCharacters(in: .whitespaces)) } }
        if let list = extended["listofdlc"] as? [Any] { dlc = list.compactMap { TextUtil.validID(String(describing: $0)) } }
        for (key, value) in app["depots"] as? [String: Any] ?? [:] {
            guard let depotID = TextUtil.validID(key), let d = value as? [String: Any], d["depotfromapp"] == nil else { continue }
            let manifests = d["manifests"] as? [String: Any] ?? [:]
            let pub = manifests["public"] as? [String: Any] ?? [:]
            let gid = pub["gid"].map { String(describing: $0) } ?? ""
            let dlcID = d["dlcappid"].flatMap { TextUtil.validID(String(describing: $0)) }
            let os = (d["config"] as? [String: Any])?["oslist"] as? String ?? "all"
            depots.append(Depot(id: depotID, manifest: gid, os: os, dlc: dlcID))
            if let dlcID { dlc.append(dlcID) }
        }
        depots.sort { $0.id < $1.id }; dlc = Array(Set(dlc)).sorted()
    }
}

public struct GenerationResult: Sendable { public var lua: String; public var warnings: [String]; public var depots: Int }
public actor ContentService {
    private var preferredCDN: String?
    public func configure(preferredCDN: String?) { self.preferredCDN = preferredCDN.flatMap { DownloadSources.validCDN($0) ? $0 : nil } }
    let api: SteamAPI
    let cache: URL
    private var providerCooldown: [String: Date] = [:]
    private var cdnCache: (Date, [String])?
    public init(api: SteamAPI, cache: URL) { self.api = api; self.cache = cache }
    public func refreshKeys(preferences: Preferences) async throws -> Int {
        let keysData = try await HTTP.get(HTTP.url(preferences.depotKeysURL), limit: 128 * 1024 * 1024)
        let keys = try parseKeys(keysData)
        guard !keys.isEmpty else { throw AppFailure("密钥源为空或格式无效 / Key source is empty or malformed") }
        try FileStore.write(keysData, to: cache.appendingPathComponent("depotkeys.json"))
        // Tokens are retained for Lua export; macSteam cannot consume them.
        return keys.count
    }
    private func parseKeys(_ data: Data) throws -> [Int: String] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure("密钥缓存格式无效 / Invalid key cache format") }
        var keys: [Int: String] = [:]
        for (id, value) in raw {
            if let n = TextUtil.validID(id), let key = value as? String, TextUtil.validKey(key) { keys[n] = key.lowercased() }
        }
        return keys
    }
    public func generate(id: Int, includeDLC: Bool, preferences: Preferences, progress: @Sendable (String) async -> Void) async throws -> GenerationResult {
        let keyURL = cache.appendingPathComponent("depotkeys.json")
        if !FileStore.fm.fileExists(atPath: keyURL.path) { await progress("正在获取 depot 密钥缓存…"); _ = try await refreshKeys(preferences: preferences) }
        let keys = try parseKeys(FileStore.read(keyURL))
        await progress("正在查询游戏和 depot…")
        let main = try await api.appInfo(id)
        var lua = "-- Fluent Steam Mac / macSteam compatible\naddappid(\(id)) -- \(TextUtil.cleanLine(main.name))\n"
        if let key = keys[id] { lua = try WorkshopKeys.adding(key, to: LuaDocument.parse(lua, suggestedID: id)).raw }
        var count = 0; var warnings: [String] = []
        for depot in main.depots where includeDLC || (depot.dlc == nil && !main.dlc.contains(depot.id)) {
            if let key = keys[depot.id] { lua += "addappid(\(depot.id), 1, \"\(key)\")\n"; count += 1 }
            else { warnings.append("Depot \(depot.id) 缺少密钥 / Missing key（\(depot.os)）") }
        }
        if includeDLC {
            for (i, dlcID) in main.dlc.enumerated() {
                try Task.checkCancellation(); await progress("查询 DLC \(i + 1) / \(main.dlc.count)…")
                do {
                    let dlc = try await api.appInfo(dlcID)
                    let matched = dlc.depots.filter { keys[$0.id] != nil }
                    if !dlc.depots.isEmpty && matched.isEmpty { warnings.append("DLC \(dlcID) 缺少全部 depot 密钥，已跳过 / No depot keys available; skipped"); continue }
                    lua += "\naddappid(\(dlcID)) -- \(TextUtil.cleanLine(dlc.name))\n"
                    for depot in matched {
                        lua += "addappid(\(depot.id), 1, \"\(keys[depot.id]!)\")\n"; count += 1
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append("DLC \(dlcID)：\(error.localizedDescription)") }
            }
        }
        guard count > 0 || main.depots.isEmpty else { throw AppFailure("该游戏没有可用 depot 密钥；无法生成可下载的清单 / No depot keys available; cannot generate a downloadable manifest") }
        return GenerationResult(lua: lua, warnings: warnings, depots: count)
    }
    public func fetchManifest(depot: Int, manifest: String, template: String, fallbacks: Bool = true, probe: Bool = false) async throws -> Data {
        guard TextUtil.validID(String(depot)) != nil, UInt64(manifest) != nil else { throw AppFailure("无效的 DepotID / ManifestID") }
        var providers = [template]
        if fallbacks {
            for source in DownloadSources.manifestTemplates where !providers.contains(source) { providers.append(source) }
        }
        var errors: [String] = []
        for provider in providers {
            try Task.checkCancellation()
            let name = URL(string: provider)?.host ?? "Manifest source"
            if fallbacks, let until = providerCooldown[provider], until > Date() { errors.append("\(name): 暂时冷却"); continue }
            do {
                let result = try await fetchFromProvider(depot: depot, manifest: manifest, template: provider)
                if !probe { providerCooldown.removeValue(forKey: provider) }; return result
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if !probe { providerCooldown[provider] = Date().addingTimeInterval(60) }
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        throw AppFailure("Manifest 获取失败 / Manifest retrieval failed：\n" + errors.joined(separator: "\n"))
    }
    private func fetchFromProvider(depot: Int, manifest: String, template: String) async throws -> Data {
        let codeURL = template.replacingOccurrences(of: "{depot}", with: String(depot)).replacingOccurrences(of: "{manifest}", with: manifest)
        let headers = codeURL.contains("manifest.manifestdex.com/") ? ["User-Agent": "ManifestDeX/1.0"] : [:]
        let data = try await HTTP.get(HTTP.url(codeURL), headers: headers, timeout: 10)
        if data.prefix(4) != SteamManifest.magic, let text = String(data: data, encoding: .utf8) {
            var code = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["manifest_request_code"] ?? object["content"] { code = String(describing: value) }
            guard let numeric = UInt64(code), numeric > 0 else { throw AppFailure("清单服务没有返回有效 request code / Manifest service returned no valid request code") }
            var errors: [String] = []
            let hosts = (preferredCDN.map { [$0] } ?? []) + ["steampipe.akamaized.net"] + (await contentServers())
            for host in hosts {
                try Task.checkCancellation()
                do {
                    let downloaded = try await HTTP.get(HTTP.url("https://\(host)/depot/\(depot)/manifest/\(manifest)/5/\(numeric)"))
                    return try unwrapManifest(downloaded, depot: depot, manifest: manifest)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    errors.append("\(host): \(error.localizedDescription)")
                }
            }
            throw AppFailure(errors.joined(separator: "; "))
        }
        return try unwrapManifest(data, depot: depot, manifest: manifest)
    }
    private func unwrapManifest(_ input: Data, depot: Int, manifest: String) throws -> Data {
        var data = input
        if data.prefix(2) == Data([0x50, 0x4b]) {
            let archive = try Archive(data: data, accessMode: .read)
            guard let entry = archive.first(where: { $0.type == .file }), entry.uncompressedSize < 64 * 1024 * 1024 else { throw AppFailure("manifest 压缩包无有效文件 / Manifest archive contains no valid file") }
            var decoded = Data()
            let checksum = try archive.extract(entry) { part in
                guard decoded.count + part.count <= 64 * 1024 * 1024 else { throw AppFailure("manifest 超过大小限制 / Manifest exceeds the size limit") }; decoded.append(part)
            }
            guard checksum == entry.checksum else { throw AppFailure("manifest CRC 校验失败 / Manifest CRC mismatch") }; data = decoded
        }
        try SteamManifest.validate(data, depot: depot, manifest: manifest)
        return data
    }
    private func contentServers() async -> [String] {
        if let cached = cdnCache, Date().timeIntervalSince(cached.0) < 600 { return cached.1 }
        do {
            let response = try await HTTP.json(HTTP.url("https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/", query: ["cell_id": "0"]))
            let servers = (response["response"] as? [String: Any])?["servers"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            let hosts = servers.sorted { ($0["weighted_load"] as? Double ?? .infinity) < ($1["weighted_load"] as? Double ?? .infinity) }.compactMap { server -> String? in
                guard server["use_as_proxy"] as? Bool != true, server["type"] as? String != "OpenCache", server["https_support"] as? String != "unavailable",
                      let host = server["host"] as? String, host.contains("."),
                      host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }), seen.insert(host).inserted else { return nil }
                return host
            }
            let bounded = Array(hosts.prefix(4)); cdnCache = (Date(), bounded); return bounded
        } catch { return [] }
    }
}

public struct WebDownload: Identifiable, Sendable {
    public var id: String { url.absoluteString }
    public var title: String
    public var url: URL
}
public enum TrainerSearch {
    public static func search(_ query: String) async throws -> [WebDownload] {
        let data = try await HTTP.get(HTTP.url("https://flingtrainer.com/", query: ["s": query]), limit: 8 * 1024 * 1024)
        let html = String(decoding: data, as: UTF8.self)
        let matches = TextUtil.matches(#"(?is)<h2[^>]*class=["'][^"']*post-title[^"']*["'][^>]*>\s*<a[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#, html)
        return matches.compactMap {
            guard let url = URL(string: $0[1]), url.host == "flingtrainer.com" else { return nil }
            return WebDownload(title: $0[2].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&#8217;", with: "'"), url: url)
        }
    }
    public static func downloadLink(_ page: URL) async throws -> URL {
        let html = String(decoding: try await HTTP.get(page, limit: 8 * 1024 * 1024), as: UTF8.self)
        for m in TextUtil.matches(#"(?is)<a\b([^>]+)>"#, html) where m[1].contains("attachment-link") {
            if let link = TextUtil.matches(#"href=["']([^"']+)["']"#, m[1]).first, let url = URL(string: link[1]), url.scheme == "https" { return url }
        }
        throw AppFailure("未找到直接下载链接；可在浏览器打开原始页面 / No direct download link found; open the original page in a browser")
    }
}
