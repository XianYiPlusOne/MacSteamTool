import Foundation

public struct InstalledGame: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var library: URL
    public var folder: URL
    public var buildID: String
    public var bytes: Int64
    public var depots: [Int: String]
    public init(id: Int, name: String, library: URL, folder: URL, buildID: String, bytes: Int64, depots: [Int: String], selectedPrefix: URL? = nil) {
        self.id = id; self.name = name; self.library = library; self.folder = folder
        self.buildID = buildID; self.bytes = bytes; self.depots = depots; self.selectedPrefix = selectedPrefix
    }
    public var prefix: URL? {
        let p = selectedPrefix ?? library.appendingPathComponent("steamapps/compatdata/\(id)/pfx")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
    public var selectedPrefix: URL? = nil
}

public enum LocalInstallations {
    public static func libraries(at steam: URL) -> [URL] {
        var roots = [steam]
        for file in [steam.appendingPathComponent("steamapps/libraryfolders.vdf"), steam.appendingPathComponent("config/libraryfolders.vdf")] {
            guard let text = try? FileStore.text(file), let vdf = try? VDF.parse(text).object("libraryfolders") else { continue }
            for entry in vdf.entries {
                if let path = entry.children?.string("path"), path.hasPrefix("/") { roots.append(URL(fileURLWithPath: path)) }
            }
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
    public static func installed(at steam: URL) -> [InstalledGame] {
        var result: [InstalledGame] = []
        for library in libraries(at: steam) {
            for manifest in FileStore.files(library.appendingPathComponent("steamapps")) where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? FileStore.text(manifest), let app = try? VDF.parse(text).object("AppState"),
                      let id = app.string("appid").flatMap(TextUtil.validID), let dir = app.string("installdir"),
                      !dir.contains("/"), !dir.contains("\\"), dir != "..", !dir.isEmpty else { continue }
                var depots: [Int: String] = [:]
                for e in app.object("InstalledDepots")?.entries ?? [] {
                    if let id = TextUtil.validID(e.key), let gid = e.children?.string("manifest") { depots[id] = gid }
                }
                result.append(InstalledGame(id: id, name: app.string("name") ?? "App \(id)", library: library,
                                            folder: library.appendingPathComponent("steamapps/common/\(dir)"),
                                            buildID: app.string("buildid") ?? "", bytes: Int64(app.string("SizeOnDisk") ?? "0") ?? 0, depots: depots))
            }
        }
        return result
    }
}
