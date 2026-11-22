import Foundation
import Testing
@testable import MacSteamToolCore

struct LocalManifestCatalogTests {
    @Test func groupsVersionsAndSharedDepotsWithoutLosingUnmatchedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let acf = #""AppState" { "appid" "10" "name" "Alpine" "installdir" "Alpine" "InstalledDepots" { "500" { "manifest" "2" } } }"#
        try FileStore.write(Data(acf.utf8), to: paths.steam.appendingPathComponent("steamapps/appmanifest_10.acf"))
        let lua = "addappid(20) -- Beacon\nsetManifestid(500, \"1\", 0)\n"
        try FileStore.write(Data(lua.utf8), to: paths.disabled.appendingPathComponent("20.lua"))
        let key = String(repeating: "a", count: 64)
        let config = "Apps:\n  - 10\n  - 11 # Add-on @10\nDepotKeys:\n  11:\n    600: \(key)\n"
        try FileStore.write(Data(config.utf8), to: paths.config)
        let info = AppInfo(id: 20, dictionary: ["depots": ["700": ["manifests": ["public": ["gid": "1"]]]]])
        try FileStore.json(info, to: paths.cache.appendingPathComponent("Metadata/appinfo-20.json"))
        for filename in ["500_1.manifest", "500_2.manifest", "600_1.manifest", "700_1.manifest",
                         "10_1.manifest", "legacy.manifest", "unrelated.txt"] {
            try FileStore.write(Data(), to: paths.depotCache.appendingPathComponent(filename))
        }
        try FileStore.mkdir(paths.depotCache.appendingPathComponent("directory.manifest"))

        let catalog = try await LocalManifestCatalog.load(paths: paths, games: SteamLibrary.games(paths))
        #expect(catalog.games.map(\.name) == ["Alpine", "Beacon"])
        #expect(catalog.fileCount == 6)
        let alpine = try #require(catalog.games.first)
        let beacon = try #require(catalog.games.last)
        #expect(alpine.entries.map(\.file.lastPathComponent) == ["500_1.manifest", "500_2.manifest", "600_1.manifest"])
        #expect(beacon.entries.map(\.file.lastPathComponent) == ["500_1.manifest", "500_2.manifest", "700_1.manifest"])
        #expect(alpine.entries.map(\.shared) == [true, true, false])
        #expect(beacon.entries.map(\.shared) == [true, true, false])
        #expect(catalog.unidentified.map(\.file.lastPathComponent) == ["10_1.manifest", "legacy.manifest"])
    }
}
