import Foundation

public struct HTTPStatusFailure: LocalizedError {
    public init(status: Int, retryAfter: Double?) { self.status = status; self.retryAfter = retryAfter }
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
        cfg.httpAdditionalHeaders = ["User-Agent": "MacSteamTool/0.1"]
        return URLSession(configuration: cfg, delegate: SourceRedirects(), delegateQueue: nil)
    }()
    public static func get(_ url: URL, limit: Int = 64 * 1024 * 1024, headers: [String: String] = [:], timeout: TimeInterval = 25, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> Data {
        guard url.scheme == "https" else { throw AppFailure("数据源必须使用 HTTPS / Data source must use HTTPS") }
        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeout)
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

public enum DownloadMirrors {
    public static let mirrors = ["direct", "https://gh-proxy.com/", "https://ghfast.top/", "https://gh-proxy.org/"]
    public static func candidates(_ url: URL, preferred: String?) -> [URL] {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.host == "github.com", url.query == nil, url.fragment == nil, mirrors.contains(preferred ?? "direct"), let preferred, preferred != "direct" else { return [url] }
        return [URL(string: preferred + url.absoluteString)!, url]
    }
}
