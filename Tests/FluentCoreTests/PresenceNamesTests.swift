import Foundation
import Testing
@testable import FluentCore

@Suite struct PresenceNamesTests {
    @Test func onlyBaseGameTitlesChangeAndOtherBytesRemainIntact() throws {
        let source = "# keep\r\nApps:  \r\n  - 480  # Spacewar\r\n  - 481  # DLC @480\r\n  - 482  # Existing\r\n\r\nPackageIds:\r\n  - 480 # package\r\nUnknown:\r\n  - 480 # opaque\r\n"
        let result = try PresenceNames.edit(Data(source.utf8), names: [480: "测试游戏", 481: "不要改 DLC", 999: "未启用"])
        #expect(String(decoding: result, as: UTF8.self) == source.replacingOccurrences(of: "  - 480  # Spacewar", with: "  - 480  # 测试游戏"))
        #expect(try MacSteamConfig.parse(String(decoding: result, as: UTF8.self)).parents[481] == 480)
        for name in ["", "   ", "bad\0name", "bad\tname", "bad @480", String(repeating: "中", count: 171)] {
            #expect(try PresenceNames.edit(Data(source.utf8), names: [480: name]) == Data(source.utf8))
        }
    }

    @Test func languageSwitchRoundTripBackupAndPrivacyChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let original = Data("Apps:\n  - 480  # Spacewar\n  - 481  # DLC @480\n".utf8)
        try FileStore.write(original, to: paths.config)
        let cache = paths.cache.appendingPathComponent("Metadata"), api = SteamAPI(cache: cache)
        try FileStore.json(GameMetadata(id: 480, name: "太空大战"), to: cache.appendingPathComponent("schinese-480.json"))
        try FileStore.json(GameMetadata(id: 480, name: "Spacewar"), to: cache.appendingPathComponent("english-480.json"))
        let zh = await api.cached(language: "schinese"), en = await api.cached(language: "english")
        #expect(try PresenceNames.synchronize(paths: paths, metadata: zh))
        let transaction = FileTransaction(backupRoot: paths.backups)
        let backup = try #require(transaction.records().first)
        #expect(try FileStore.read(paths.backups.appendingPathComponent(backup.id).appendingPathComponent(backup.files[0].stored)) == original)
        #expect(try FileStore.text(paths.config).contains("# 太空大战"))
        #expect(try !PresenceNames.synchronize(paths: paths, metadata: zh))
        #expect(transaction.records().count == 1)
        #expect(try PresenceNames.synchronize(paths: paths, metadata: en))
        #expect(try FileStore.read(paths.config) == original)
        #expect(try PresenceNames.synchronize(paths: paths, metadata: zh))
        try transaction.restore(backup, allowedRoots: [paths.macSteam])
        #expect(try FileStore.read(paths.config) == original)
        for mode in [FriendPresence.none, .unchanged, .selected] {
            var features = RuntimeFeatures(); features.presence = mode; try features.save(paths: paths)
            #expect(try !PresenceNames.synchronize(paths: paths, metadata: zh))
            #expect(try FileStore.read(paths.config) == original)
        }
    }

    @Test func selectedPresenceNamesFollowLanguageWithoutExpandingScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let original = "Apps:\n  - 4348910  # Probably Stolen\n  - 3321460  # Keep this title\n"
        try FileStore.write(Data(original.utf8), to: paths.config)
        var features = RuntimeFeatures(); features.presence = .selected; features.presenceApps = ["4348910": "Old title"]
        try features.save(paths: paths)
        #expect(try PresenceNames.synchronize(paths: paths, metadata: [4348910: GameMetadata(id: 4348910, name: "深空当铺"), 3321460: GameMetadata(id: 3321460, name: "Unselected replacement")]))
        #expect(try FileStore.text(paths.config) == original.replacingOccurrences(of: "Probably Stolen", with: "深空当铺"))
        #expect(try RuntimeFeatures.load(paths: paths).presenceApps == features.presenceApps)
    }

    @Test func missingOrMismatchedMetadataKeepsCurrentFallbackTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root), original = Data("Apps:\n  - 480  # Spacewar\n".utf8)
        try FileStore.write(original, to: paths.config)
        #expect(try !PresenceNames.synchronize(paths: paths, metadata: [:]))
        #expect(try !PresenceNames.synchronize(paths: paths, metadata: [480: GameMetadata(id: 481, name: "Wrong game")]))
        #expect(try FileStore.read(paths.config) == original)
        #expect(FileTransaction(backupRoot: paths.backups).records().isEmpty)
    }
}
