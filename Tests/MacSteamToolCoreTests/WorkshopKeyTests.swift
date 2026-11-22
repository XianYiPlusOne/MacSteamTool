import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct WorkshopKeyTests {
    let key = String(repeating: "ab", count: 32)
    @Test func appDepotKeySurvivesLuaConfigAndDLCGrouping() throws {
        let raw = "-- fixture\r\naddappid(480) -- Main\r\naddappid(481) -- DLC\r\naddappid(482, 1, \"\(String(repeating: "cd", count: 32))\")\r\n"
        let doc = try WorkshopKeys.adding(key, to: LuaDocument.parse(raw))
        var config = MacSteamConfig(); try config.merge(doc)
        #expect(config.topLevel == [480]); #expect(config.children(480) == [481])
        #expect(config.keys[480]?[480] == key); #expect(config.keys[481]?[480] == nil)
        #expect(config.keys[481]?[482] == String(repeating: "cd", count: 32))
        #expect(try WorkshopKeys.adding(key, to: doc).raw == doc.raw)
        #expect(doc.raw.replacingOccurrences(of: "addappid(480, 1, \"\(key)\")\r\n", with: "") == raw)
        #expect(throws: (any Error).self) { try WorkshopKeys.adding(String(repeating: "cd", count: 32), to: doc) }
    }
    @Test func repairIsScopedBackedUpAndSurvivesDisableEnable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root), lua = paths.lua.appendingPathComponent("480.lua")
        let raw = "addappid(480) -- Main\naddappid(481, 1, \"\(String(repeating: "cd", count: 32))\")\n"
        var config = MacSteamConfig(); try config.merge(LuaDocument.parse(raw))
        try config.merge(LuaDocument.parse("addappid(490) -- Other\n")); config.unknown = ["OtherSetting: keep"]
        let original = Data(config.serialized().utf8)
        try FileStore.write(original, to: paths.config); try FileStore.write(Data(raw.utf8), to: lua)
        try FileStore.json(["480": key, "490": String(repeating: "ef", count: 32)], to: paths.cache.appendingPathComponent("depotkeys.json"))
        let repaired = try WorkshopKeys.repair(appID: 480, paths: paths)
        let record = try #require(repaired)
        let actual = try MacSteamConfig.parse(FileStore.text(paths.config))
        var expected = config; expected.keys[480, default: [:]][480] = key
        #expect(actual.serialized() == expected.serialized()); #expect(record.files.count == 2)
        #expect(try WorkshopKeys.repair(appID: 480, paths: paths) == nil)
        let service = LibraryService(paths: paths)
        var game = try #require(SteamLibrary.games(paths).first { $0.id == 480 })
        try service.setEnabled(game, enabled: false)
        game = try #require(SteamLibrary.games(paths).first { $0.id == 480 })
        try service.setEnabled(game, enabled: true)
        #expect(try MacSteamConfig.parse(FileStore.text(paths.config)).keys[480]?[480] == key)
        try FileTransaction(backupRoot: paths.backups).restore(record, allowedRoots: [paths.macSteam, paths.lua])
        #expect(try FileStore.read(paths.config) == original); #expect(try FileStore.text(lua) == raw)
    }
    @Test func missingCacheDisabledGameAndConflictNeverWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root), original = Data("Apps:\n  - 480  # Main\n".utf8)
        try FileStore.write(original, to: paths.config)
        #expect(throws: (any Error).self) { try WorkshopKeys.repair(appID: 480, paths: paths) }
        try FileStore.json(["480": key, "490": key], to: paths.cache.appendingPathComponent("depotkeys.json"))
        #expect(throws: (any Error).self) { try WorkshopKeys.repair(appID: 490, paths: paths) }
        #expect(try FileStore.read(paths.config) == original)
        #expect(FileTransaction(backupRoot: paths.backups).records().isEmpty)
        var config = try MacSteamConfig.parse(String(decoding: original, as: UTF8.self)); config.keys[480] = [480: key]
        let conflicting = Data(config.serialized().utf8); try FileStore.write(conflicting, to: paths.config)
        try FileStore.write(Data("addappid(480, 1, \"\(String(repeating: "cd", count: 32))\")\n".utf8), to: paths.lua.appendingPathComponent("480.lua"))
        #expect(throws: (any Error).self) { try WorkshopKeys.repair(appID: 480, paths: paths) }
        #expect(try FileStore.read(paths.config) == conflicting)
        #expect(FileTransaction(backupRoot: paths.backups).records().isEmpty)
    }
}
