import Foundation

/// Save history outlives both a library entry and the disposable Store cache.
public struct SaveGameMetadata: Codable, Equatable, Sendable {
    public var name: String?
    public var localizedNames: [String: String] = [:]
    public var image: String?
    public init() {}

    static func title(_ value: String?, id: Int) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.caseInsensitiveCompare("App \(id)") != .orderedSame, name != String(id) else { return nil }
        return name
    }

    public func displayName(language: String) -> String? {
        localizedNames[language] ?? name ?? localizedNames["schinese"] ?? localizedNames["english"]
    }
}

public enum SaveGameMetadataStore {
    public static func covers(_ paths: AppPaths) -> URL { paths.data.appendingPathComponent("SaveManager/Covers") }

    /// Merge under a short lock so independent windows/processes retain each other's entries.
    @discardableResult public static func remember(paths: AppPaths, games: [Game] = [], localized: [GameMetadata] = [],
                                                  language: String = "schinese", localNames: [Int: String] = [:]) throws -> [Int: SaveGameMetadata] {
        let folder = paths.data.appendingPathComponent("SaveManager")
        let file = folder.appendingPathComponent("game-metadata.json")
        try FileStore.mkdir(folder)
        let lock = open(folder.appendingPathComponent(".metadata-lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        let old = FileStore.fm.fileExists(atPath: file.path) ? try FileStore.decode([Int: SaveGameMetadata].self, at: file) : [:]
        var result = old
        for (id, value) in localNames where result[id]?.name == nil {
            if let name = SaveGameMetadata.title(value, id: id) { result[id, default: .init()].name = name }
        }
        for game in games {
            if let name = SaveGameMetadata.title(game.name, id: game.id) ?? SaveGameMetadata.title(game.installed?.name, id: game.id) {
                result[game.id, default: .init()].name = name
            }
        }
        for item in localized {
            if let name = SaveGameMetadata.title(item.name, id: item.id) { result[item.id, default: .init()].localizedNames[language] = name }
            if let image = GameCovers.asset(item.image, appID: item.id) { result[item.id, default: .init()].image = image.absoluteString }
        }
        if old != result { try FileStore.json(result, to: file) }
        return result
    }

    /// The bundled reader understands the different Steam appinfo.vdf formats, including non-store apps.
    public static func steamNames(ids: Set<Int>, paths: AppPaths, application: URL = Bundle.main.bundleURL) async -> [Int: String] {
        let file = paths.steam.appendingPathComponent("appcache/appinfo.vdf")
        guard !ids.isEmpty, FileStore.fm.fileExists(atPath: file.path),
              let version = ManagedRuntimeComponents.versions["notproton"] else { return [:] }
        let reader = application.appendingPathComponent("Contents/Resources/RuntimeComponents/notproton/\(version)/NotProtonRuntime.bundle/Contents/Resources/payload/appinfo")
        guard FileStore.fm.isExecutableFile(atPath: reader.path) else { return [:] }
        let sorted = ids.sorted()
        var names: [Int: String] = [:]
        for start in stride(from: 0, to: sorted.count, by: 256) {
            guard !Task.isCancelled else { break }
            let batch = sorted[start..<min(start + 256, sorted.count)]
            let list = batch.map(String.init).joined(separator: ",")
            guard let (code, text) = try? await ProcessRunner.run(reader, [file.path, "--names", list]), code == 0,
                  let values = try? JSONDecoder().decode([Int: String].self, from: Data(text.utf8)) else { continue }
            names.merge(values) { first, _ in first }
        }
        return names
    }
}
