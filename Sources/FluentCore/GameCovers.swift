import Foundation
import ImageIO

/// Shared cover loading for library, search, details and charts. Save manager artwork can also be retained with local save metadata.
public actor GameCovers {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Metadata = @Sendable (Int) async throws -> String?
    private struct Key: Hashable { let app: Int; let reference: String?; let steam: String? }
    private struct Record: Codable { let reference: String?; let source: String; let date: Date }
    private let archive: URL?
    private let cache: URL
    private let fetch: Fetch
    private let metadata: Metadata
    private var memory: [Key: Data] = [:]
    private var inFlight: [Key: Task<Data, Error>] = [:]
    private var failed: [Key: Date] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(cache: URL, archive: URL? = nil, fetch: @escaping Fetch = GameCovers.fetchImage, metadata: @escaping Metadata = GameCovers.storeImage) {
        self.archive = archive; self.cache = cache; self.fetch = fetch; self.metadata = metadata
    }
    public static func fetchImage(_ url: URL) async throws -> Data {
        let heybox = ["heyboxbj.max-c.com", "cdn.max-c.com"].contains(url.host ?? "")
        let headers = heybox ? ["Referer": "https://www.xiaoheihe.cn/", "User-Agent": "Mozilla/5.0", "Accept": "image/webp,image/*;q=0.9,*/*;q=0.8"] : [:]
        for attempt in 0...1 {
            do { return try await HTTP.get(url, limit: 8*1024*1024, headers: headers, timeout: heybox ? 10 : 6) }
            catch let error as URLError where heybox && attempt == 0 && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(error.code) {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw AppFailure("图片连接失败 / Image connection failed")
    }
    public static func validImage(_ data: Data) -> Bool {
        guard data.count <= 8*1024*1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width*height <= 16_000_000 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }
    public static func asset(_ raw: String?, appID: Int) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443, !url.path.contains("..") else { return nil }
        let steam = (host.hasSuffix(".steamstatic.com") || host == "steamcdn-a.akamaihd.net") && url.path.contains("/steam/apps/\(appID)/")
        // The chart's authoritative game_img also uses hash-only paths without AppID.
        let heybox = ["heyboxbj.max-c.com", "cdn.max-c.com"].contains(host) && (url.path.hasPrefix("/gameimg/") || url.path.hasPrefix("/heybox/game/"))
        guard steam || heybox else { return nil }
        return url
    }
    /// Preserve hashed directory, localized filename and version query from Steam.
    public static func candidates(appID: Int, reference: String?) -> [URL] {
        guard let source = asset(reference, appID: appID) else { return [] }
        var values = [source]
        if ["heyboxbj.max-c.com", "cdn.max-c.com"].contains(source.host ?? "") { return values }
        for host in DownloadSources.imageHosts {
            var parts = URLComponents(url: source, resolvingAgainstBaseURL: false)!; parts.host = host
            if let url = parts.url, !values.contains(url) { values.append(url) }
        }
        return values
    }
    public static func legacyCandidates(appID: Int) -> [URL] {
        DownloadSources.imageHosts.flatMap { host in ["/store_item_assets/steam/apps/\(appID)/header.jpg", "/steam/apps/\(appID)/header.jpg"].map { URL(string: "https://\(host)\($0)")! } }
    }
    public static func storeImage(_ appID: Int) async throws -> String? {
        for region in ["cn", "us"] {
            try Task.checkCancellation()
            let url = try HTTP.url("https://store.steampowered.com/api/appdetails", query: ["appids": String(appID), "l": "schinese", "cc": region])
            let bytes = try await HTTP.get(url, limit: 4*1024*1024, timeout: 6)
            let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            if let item = body?[String(appID)] as? [String: Any], item["success"] as? Bool == true,
               let data = item["data"] as? [String: Any], let image = data["header_image"] as? String, asset(image, appID: appID) != nil { return image }
        }
        return nil
    }
    /// Immediate artwork for the same app while a changed source refreshes in background.
    public func cachedImage(appID: Int, steam: URL? = nil) -> Data? {
        guard appID > 0, UInt32(exactly: appID) != nil else { return nil }
        if let data = memory.first(where: { $0.key.app == appID })?.value { return data }
        if let data = try? FileStore.read(cache.appendingPathComponent("\(appID).image")), Self.validImage(data) { return data }
        return local(Key(app: appID, reference: nil, steam: steam?.path)) ?? archived(appID)
    }

    private func archived(_ id: Int) -> Data? {
        guard let file = archive?.appendingPathComponent("\(id).image"),
              let data = try? FileStore.read(file), Self.validImage(data) else { return nil }
        return data
    }

    public func retain(_ data: Data, appID: Int) throws {
        guard let file = archive?.appendingPathComponent("\(appID).image"), Self.validImage(data) else { return }
        if (try? FileStore.read(file)) != data { try FileStore.write(data, to: file) }
    }

    public func retainCached(appID: Int, steam: URL) throws {
        if let data = cachedImage(appID: appID, steam: steam) { try retain(data, appID: appID) }
    }
    public func load(appID: Int, reference: String? = nil, steam: URL? = nil, force: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard appID > 0, UInt32(exactly: appID) != nil else { throw AppFailure("无效封面 AppID / Invalid cover AppID") }
        let key = Key(app: appID, reference: Self.asset(reference, appID: appID)?.absoluteString, steam: steam?.path)
        if !force, let data = memory[key] { return data }
        if let task = inFlight[key] { return try await task.value }
        if !force, let date = failed[key], Date().timeIntervalSince(date) < 30 { throw AppFailure("封面暂时不可用，可点击重试 / Cover unavailable; click to retry") }
        let task = Task { [self] in
            await acquire(); defer { release() }
            return try await resolve(key, force: force)
        }
        inFlight[key] = task
        do {
            let data = try await task.value; inFlight.removeValue(forKey: key); failed.removeValue(forKey: key)
            if memory.count >= 48 { memory.removeAll(keepingCapacity: true) }
            memory[key] = data; return data
        } catch {
            inFlight.removeValue(forKey: key)
            if !(error is CancellationError) { failed[key] = Date() }
            throw error
        }
    }
    private func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() { if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() } }
    private func local(_ key: Key) -> Data? {
        guard let steam = key.steam else { return nil }
        let root = URL(fileURLWithPath: steam).appendingPathComponent("appcache/librarycache")
        let folder = root.appendingPathComponent(String(key.app))
        // Steam also stores localized headers one level below the AppID, in a hash directory.
        func rank(_ file: URL) -> Int {
            let name = file.lastPathComponent.lowercased()
            if name.contains("header") { return 0 }
            if name.contains("capsule") || name.contains("600x900") { return 1 }
            if name.contains("library_hero") && !name.contains("blur") { return 2 }
            return 3
        }
        let children = FileStore.files(folder)
        let nested = children.filter {
            $0.lastPathComponent.count == 40 && $0.lastPathComponent.allSatisfy(\.isHexDigit) &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } == true
        }
        let legacy = ["header.jpg", "header.png", "library_600x900.jpg"].map { root.appendingPathComponent("\(key.app)_\($0)") }
        let files = (legacy + children + nested.flatMap(FileStore.files)).filter {
            ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) && rank($0) < 3
        }.sorted { (rank($0), $0.path) < (rank($1), $1.path) }
        for file in files {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? FileStore.read(file), Self.validImage(data) else { continue }
            return data
        }
        return nil
    }
    private func resolve(_ key: Key, force: Bool) async throws -> Data {
        let file = cache.appendingPathComponent("\(key.app).image"), info = cache.appendingPathComponent("\(key.app).json")
        let stale = (try? FileStore.read(file)).flatMap { Self.validImage($0) ? $0 : nil }
        if !force {
            if let data = local(key) { return data }
            if let stale, let record = try? FileStore.decode(Record.self, at: info), record.reference == key.reference, Date().timeIntervalSince(record.date) < 7*86400 { return stale }
        }
        var attempted = Set<URL>()
        func download(_ urls: [URL]) async -> (Data, URL)? {
            for url in urls where attempted.insert(url).inserted {
                do {
                    try Task.checkCancellation()
                    let bytes = try await fetch(url)
                    if Self.validImage(bytes) { return (bytes, url) }
                } catch is CancellationError { return nil }
                catch { continue }
            }
            return nil
        }
        var found = await download(Self.candidates(appID: key.app, reference: key.reference))
        if found == nil, let reference = try? await metadata(key.app) { found = await download(Self.candidates(appID: key.app, reference: reference)) }
        if found == nil { found = await download(Self.legacyCandidates(appID: key.app)) }
        if let (data, source) = found {
            // Cache failures must not hide a successfully downloaded image.
            try? FileStore.write(data, to: file)
            try? FileStore.json(Record(reference: key.reference, source: source.absoluteString, date: Date()), to: info)
            return data
        }
        if let stale { return stale }
        if let data = archived(key.app) { return data }
        throw AppFailure("封面加载失败，可点击重试 / Cover could not be loaded; click to retry")
    }
}
