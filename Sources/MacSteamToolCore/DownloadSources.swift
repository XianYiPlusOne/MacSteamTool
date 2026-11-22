import Foundation
public enum DownloadSources {
    public static let manifestTemplates = ["https://20770407.xyz/manifest/{depot}/{manifest}", "https://steamapi.993499094.xyz/manifest/{depot}/{manifest}", "https://manifest.manifestdex.com/{manifest}", "https://manifest.steam.run/api/manifest/{manifest}", "https://manifest.opensteamtool.com/{manifest}"]
    public static let imageHosts = ["shared.akamai.steamstatic.com", "shared.fastly.steamstatic.com", "cdn.akamai.steamstatic.com", "cdn.cloudflare.steamstatic.com"]
    public static let mirrors = DownloadMirrors.mirrors
    public static func candidates(_ url: URL, preferred: String?) -> [URL] { DownloadMirrors.candidates(url, preferred: preferred) }
    public static func validCDN(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    public struct Measurement: Identifiable, Sendable {
        public let id: String; public let milliseconds: Int; public let bytes: Int; public let error: String?
    }
    public static func validImage(_ data: Data) -> Bool {
        data.starts(with: [0xff, 0xd8, 0xff]) || data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }
    public static func measureImageCDNs(appID: Int = 620) async -> [Measurement] {
        await withTaskGroup(of: Measurement.self) { group in
            for host in imageHosts {
                group.addTask {
                    let start = Date()
                    do {
                        try Task.checkCancellation()
                        let data = try await HTTP.get(HTTP.url("https://\(host)/store_item_assets/steam/apps/\(appID)/header.jpg"), limit: 4 * 1024 * 1024, timeout: 12)
                        guard validImage(data) else { throw AppFailure("未返回图片 / Response is not an image") }
                        return Measurement(id: host, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: data.count, error: nil)
                    } catch { return Measurement(id: host, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: 0, error: error.localizedDescription) }
                }
            }
            var values: [Measurement] = []; for await value in group { values.append(value) }
            return values.sorted { ($0.error == nil ? $0.milliseconds : Int.max) < ($1.error == nil ? $1.milliseconds : Int.max) }
        }
    }
    /// Runs each source without fallback, using an actual depot/manifest pair. Does not cache or install content.
    public static func probeManifests(depot: Int, manifest: String, preferred: String, content: ContentService) async throws -> [Measurement] {
        guard TextUtil.validID(String(depot)) != nil, let id = UInt64(manifest), id > 0 else { throw AppFailure("请选择有效 Depot / Manifest / Select a valid depot and manifest") }
        var results: [Measurement] = []
        var seen = Set<String>()
        for template in [preferred] + manifestTemplates where seen.insert(template).inserted {
            try Task.checkCancellation()
            let start = Date()
            do {
                let data = try await content.fetchManifest(depot: depot, manifest: manifest, template: template, fallbacks: false, probe: true)
                results.append(Measurement(id: template, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: data.count, error: nil))
            } catch is CancellationError { throw CancellationError() }
            catch { results.append(Measurement(id: template, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: 0, error: error.localizedDescription)) }
        }
        return results
    }
    public static func measureMirrors() async -> [Measurement] {
        let source = URL(string: "https://github.com/weichsel/ZIPFoundation/raw/22787ffb59de99e5dc1fbfe80b19c97a904ad48d/Package.swift")!
        return await withTaskGroup(of: Measurement.self) { group in
            for mirror in mirrors {
                group.addTask {
                    let start = Date(), url = candidates(source, preferred: mirror)[0]
                    do {
                        let data = try await HTTP.get(url, limit: 512 * 1024, timeout: 12)
                        guard FileStore.hash(data) == "2dd90c2f70b1f3d17a4d73bd32ac97e5fc002eecd5797586edaf170def789fff" else { throw AppFailure("非预期内容 / Unexpected content") }
                        return Measurement(id: mirror, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: data.count, error: nil)
                    } catch { return Measurement(id: mirror, milliseconds: Int(Date().timeIntervalSince(start) * 1000), bytes: 0, error: error.localizedDescription) }
                }
            }
            var values: [Measurement] = []; for await value in group { values.append(value) }
            return values.sorted { ($0.error == nil ? $0.milliseconds : Int.max) < ($1.error == nil ? $1.milliseconds : Int.max) }
        }
    }
}
