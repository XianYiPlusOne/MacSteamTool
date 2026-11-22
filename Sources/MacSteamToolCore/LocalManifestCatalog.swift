import Foundation

public struct LocalManifestCatalog: Sendable {
    public struct Entry: Identifiable, Sendable {
        public var id: URL { file }
        public let file: URL
        public let shared: Bool
    }

    public struct GameGroup: Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let entries: [Entry]
    }

    public let games: [GameGroup]
    public let unidentified: [Entry]
    public let fileCount: Int

    public static func load(paths: AppPaths, games: [Game]) async throws -> Self {
        let files = FileStore.files(paths.depotCache).filter {
            $0.pathExtension.lowercased() == "manifest" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { return Self(games: [], unidentified: [], fileCount: 0) }

        let config = try? LibraryService(paths: paths).configSnapshot().0
        let metadata = paths.cache.appendingPathComponent("Metadata")
        var owners: [Int: Set<Int>] = [:]
        var names: [Int: String] = [:]
        for game in games {
            try Task.checkCancellation()
            var depots = Set((game.installed?.depots ?? [:]).keys)
            let children = Set(game.dlcIDs).union(config?.children(game.id) ?? [])
            var nameCandidates = [game.name, game.installed?.name]
            if let lua = game.luaURL, let text = try? FileStore.text(lua),
               let document = try? LuaDocument.parse(text, suggestedID: game.id) {
                depots.formUnion(document.depots.map(\.id))
                depots.formUnion(document.pins.map(\.depot))
                nameCandidates.append(document.name)
            }
            for app in [game.id] + children {
                depots.formUnion((config?.keys[app] ?? [:]).keys)
                depots.formUnion((config?.manifestPins[app] ?? [:]).keys)
                let file = metadata.appendingPathComponent("appinfo-\(app).json")
                if let info = try? FileStore.decode(AppInfo.self, at: file), info.id == app {
                    depots.formUnion(info.depots.map(\.id))
                    depots.formUnion((info.sharedDepots ?? []).map(\.id))
                    if app == game.id { nameCandidates.append(info.name) }
                }
            }
            let fallback = "App \(game.id)"
            names[game.id] = nameCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != fallback } ?? fallback
            for depot in depots { owners[depot, default: []].insert(game.id) }
        }

        var grouped: [Int: [Entry]] = [:]
        var unidentified: [Entry] = []
        for file in files {
            let parts = file.deletingPathExtension().lastPathComponent.components(separatedBy: "_")
            guard parts.count == 2, let depot = TextUtil.validID(parts[0]), (UInt64(parts[1]) ?? 0) > 0,
                  let apps = owners[depot] else {
                unidentified.append(Entry(file: file, shared: false))
                continue
            }
            let entry = Entry(file: file, shared: apps.count > 1)
            for app in apps { grouped[app, default: []].append(entry) }
        }
        let groups = grouped.map { app, entries in
            GameGroup(id: app, name: names[app] ?? "App \(app)", entries: entries)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return Self(games: groups, unidentified: unidentified, fileCount: files.count)
    }
}
