import Foundation

private final class AssetTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int
    let hosts: Set<String>?
    init(limit: Int, hosts: Set<String>?) { self.limit = limit; self.hosts = hosts }

    func accepts(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host else { return false }
        return hosts?.contains(host) ?? true
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(accepts(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

struct ReleaseAsset {
    let tag: String
    let name: String
    let url: URL
    let sha256: String
    let notes: String?

    init(repository: String, tag: String, name: String, url: String, digest: String, notes: String? = nil) throws {
        let expected = "https://github.com/\(repository)/releases/download/\(tag)/\(name)"
        guard Self.validTag(tag), url == expected, let address = URL(string: expected),
              digest.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            throw AppFailure("官方资源地址或摘要无效 / Invalid official release URL or SHA-256")
        }
        self.tag = tag; self.name = name; self.url = address; self.sha256 = String(digest.dropFirst(7)); self.notes = notes
    }
    static func validTag(_ tag: String) -> Bool {
        tag.range(of: #"\A[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}\z"#, options: .regularExpression) != nil
    }
}

enum ReleaseAssets {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": "MacSteamTool"]
        return URLSession(configuration: config)
    }()

    private static func transfer<T>(_ url: URL, limit: Int, hosts: Set<String>?,
                                    consume: (URL, URL) throws -> T) async throws -> T {
        let delegate = AssetTransfer(limit: limit, hosts: hosts)
        guard delegate.accepts(url) else { throw AppFailure("Invalid download location") }
        let (temp, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        defer { try? FileStore.fm.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, delegate.accepts(final),
              let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else {
            throw AppFailure("下载失败或超过大小限制 / Download failed or exceeds size limit")
        }
        try Task.checkCancellation()
        return try consume(temp, final)
    }
    private static func metadata(_ url: URL, exact: Bool = true) async throws -> (Data, URL) {
        try await transfer(url, limit: 2 * 1024 * 1024, hosts: [url.host!]) { temp, final in
            guard !exact || final == url else { throw AppFailure("Unexpected release metadata redirect") }
            return (try Data(contentsOf: temp), final)
        }
    }

    static func download(_ url: URL, sha256: String, to file: URL, hosts: Set<String>? = nil) async throws {
        try await transfer(url, limit: 256 * 1024 * 1024, hosts: hosts) { temp, _ in
            try storeVerified(temp, sha256: sha256, to: file)
        }
    }

    static func storeVerified(_ temp: URL, sha256: String, to file: URL) throws {
        guard FileStore.hash(try Data(contentsOf: temp, options: .mappedIfSafe)) == sha256 else {
            throw AppFailure("下载文件 SHA-256 不符 / Download digest mismatch")
        }
        try Task.checkCancellation()
        try FileStore.fm.moveItem(at: temp, to: file)
    }

    static func resolve(repository: String, tag: String? = nil, name: (String) -> String) async throws -> ReleaseAsset {
        if let tag, !ReleaseAsset.validTag(tag) { throw AppFailure("Invalid release tag") }
        let requested = tag.map { "tags/" + $0 } ?? "latest"
        let api = URL(string: "https://api.github.com/repos/\(repository)/releases/\(requested)")!
        do {
            let (json, _) = try await metadata(api)
            return try parseJSON(json, repository: repository, requestedTag: tag, name: name)
        } catch { try Task.checkCancellation() }
        let root = "https://github.com/\(repository)/releases/"
        let (page, final) = try await metadata(URL(string: root + (tag.map { "tag/" + $0 } ?? "latest"))!, exact: tag != nil)
        let actual = final.lastPathComponent
        guard ReleaseAsset.validTag(actual), tag == nil || tag == actual,
              final.absoluteString == root + "tag/" + actual else { throw AppFailure("Unexpected release location") }
        let (assets, _) = try await metadata(URL(string: root + "expanded_assets/" + actual)!)
        return try parseHTML(assets, page: page, repository: repository, tag: actual, name: name(actual))
    }

    static func parseJSON(_ data: Data, repository: String, requestedTag: String?, name: (String) -> String) throws -> ReleaseAsset {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String? }
            let tag_name: String; let body: String?; let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let tag = release.tag_name, filename = name(tag)
        let matches = release.assets.filter { $0.name == filename }
        guard requestedTag == nil || requestedTag == tag, matches.count == 1, let asset = matches.first else {
            throw AppFailure("Missing or ambiguous release asset")
        }
        return try ReleaseAsset(repository: repository, tag: tag, name: filename, url: asset.browser_download_url, digest: asset.digest ?? "", notes: release.body)
    }

    static func parseHTML(_ data: Data, page: Data, repository: String, tag: String, name: String) throws -> ReleaseAsset {
        let options: XMLNode.Options = [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
        guard ReleaseAsset.validTag(tag) else { throw AppFailure("Invalid release tag") }
        // Foundation's HTML tidy drops custom elements. Preserve the digest control
        // as a standard element before parsing the page and its attributes.
        let html = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"<clipboard-copy(?=[\s>])"#, with: "<input type='hidden' data-release-digest='1'", options: .regularExpression)
            .replacingOccurrences(of: "</clipboard-copy>", with: "")
        let doc = try XMLDocument(data: Data(html.utf8), options: options)
        let path = "/\(repository)/releases/download/\(tag)/\(name)"
        let label = "Copy to clipboard digest for " + name
        func elements(_ expression: String) throws -> [XMLElement] {
            try doc.nodes(forXPath: expression).compactMap { $0 as? XMLElement }
        }
        let links = try elements("//a").filter { $0.attribute(forName: "href")?.stringValue == path }
        let digests = try elements("//input[@data-release-digest='1']").filter { $0.attribute(forName: "aria-label")?.stringValue == label }
        guard !links.isEmpty, digests.count == 1, let digest = digests.first?.attribute(forName: "value")?.stringValue else {
            throw AppFailure("官方发布页缺少资源或校验值 / Missing official asset or digest")
        }
        let document = try? XMLDocument(data: page, options: options)
        let body = try document?.nodes(forXPath: "//*[contains(concat(' ',normalize-space(@class),' '),' markdown-body ')]").first
        let notes = body.map { releaseNotes($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return try ReleaseAsset(repository: repository, tag: tag, name: name, url: "https://github.com" + path, digest: digest, notes: notes)
    }

    private static func releaseNotes(_ node: XMLNode) -> String {
        if node.kind == .text { return node.stringValue ?? "" }
        let children = (node.children ?? []).map(releaseNotes).joined()
        let trimmed = children.trimmingCharacters(in: .whitespacesAndNewlines)
        switch node.name {
        case "script", "style": return ""
        case "br": return "\n"
        case "div", "p": return "\n" + children + "\n"
        case "li": return "\n- " + trimmed
        case "strong", "b": return "**" + children + "**"
        case "em", "i": return "*" + children + "*"
        case "code": return "`" + children + "`"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return "\n\n" + String(repeating: "#", count: Int(node.name!.dropFirst())!) + " " + trimmed + "\n"
        case "a":
            guard let link = (node as? XMLElement)?.attribute(forName: "href")?.stringValue,
                  URL(string: link)?.scheme == "https" else { return children }
            return "[" + trimmed + "](" + link + ")"
        default: return children
        }
    }
}
