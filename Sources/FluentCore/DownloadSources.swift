import Foundation
public enum DownloadSources {
    public static let mirrors = ["direct", "https://gh-proxy.com/", "https://ghfast.top/", "https://gh-proxy.org/"]
    public static func candidates(_ url: URL, preferred: String?) -> [URL] {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.host == "github.com", url.query == nil, url.fragment == nil, mirrors.contains(preferred ?? "direct"), let preferred, preferred != "direct" else { return [url] }
        return [URL(string: preferred + url.absoluteString)!, url]
    }
    public static func validCDN(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    public struct Measurement: Identifiable, Sendable {
        public let id: String; public let milliseconds: Int; public let bytes: Int; public let error: String?
    }
    public static func measureMirrors() async -> [Measurement] {
        let source = URL(string: "https://github.com/huanyuejue/Fluent-Steam-Lua/raw/refs/heads/main/README.md")!
        return await withTaskGroup(of: Measurement.self) { group in
            for mirror in mirrors {
                group.addTask {
                    let start = Date(), url = candidates(source, preferred: mirror)[0]
                    do {
                        let data = try await HTTP.get(url, limit: 512 * 1024, timeout: 12)
                        let text = String(decoding: data, as: UTF8.self)
                        guard text.contains("Fluent-Steam-Lua"), !text.lowercased().contains("<html") else { throw AppFailure("非预期内容 / Unexpected content") }
                        return Measurement(id: mirror, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: data.count, error: nil)
                    } catch { return Measurement(id: mirror, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: 0, error: error.localizedDescription) }
                }
            }
            var values: [Measurement] = []; for await value in group { values.append(value) }
            return values.sorted { ($0.error == nil ? $0.milliseconds : Int.max) < ($1.error == nil ? $1.milliseconds : Int.max) }
        }
    }
}
