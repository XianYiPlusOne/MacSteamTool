import Foundation
import Testing
@testable import FluentCore

@Suite struct LibraryRestoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryRestore-\(UUID().uuidString)")
    var paths: AppPaths { AppPaths(home: root) }
    var service: LibraryService { LibraryService(paths: paths) }
    var journal: FileTransaction { FileTransaction(backupRoot: paths.backups) }
    let key = String(repeating: "ab", count: 32)
    func install(_ id: Int, extra: String = "") throws {
        let text = "addappid(\(id))\naddappid(\(id + 1),1,\"\(key)\")\n" + extra
        try service.perform(service.plan([ImportFile(name: "\(id).lua", data: Data(text.utf8))]))
    }
    func game(_ id: Int) throws -> Game { try #require(SteamLibrary.games(paths).first { $0.id == id }) }
    func remove(_ id: Int) throws -> BackupRecord {
        try service.remove(game(id))
        return try #require(journal.records().first { $0.libraryAppIDs == [id] })
    }

    @Test func restorePreservesOtherGamesGlobalsAndQueuesAndCanBeUndone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try install(480, extra: "addtoken(480,'123')\nsetManifestid(481,'456')\naddappid(490)\naddappid(491,1,\"\(key)\")\n")
        let original = try FileStore.read(paths.lua.appendingPathComponent("480.lua"))
        let backup = try remove(480)
        try install(580, extra: "addtoken(580,'987')\n")
        var current = try service.configSnapshot().0
        current.hideWhatsNew = true; current.packages = [777]; current.unknown = ["FutureFlag: 42"]
        try FileStore.write(Data(current.serialized().utf8), to: paths.config)
        let otherLua = try FileStore.read(paths.lua.appendingPathComponent("580.lua"))
        let otherJob = try AutomaticCompatibility.state(paths: paths).jobs[580]
        let otherAchievement = try AutomaticAchievements.state(paths: paths).jobs[580]
        try service.restoreBackup(backup)
        let restored = try service.configSnapshot().0
        #expect(restored.keys[480]?[481] == key)
        #expect(restored.accessTokens[480] == "123")
        #expect(restored.manifestPins[480]?[481] == "456")
        #expect(restored.parents[490] == 480); #expect(restored.keys[490]?[491] == key)
        #expect(restored.lua(for: 580) == current.lua(for: 580))
        let expectedGlobals = try MacSteamConfig.parse(current.serialized())
        #expect(restored.hideWhatsNew && restored.packages == [777] && restored.unknown == expectedGlobals.unknown)
        #expect(try FileStore.read(paths.lua.appendingPathComponent("480.lua")) == original)
        #expect(try FileStore.read(paths.lua.appendingPathComponent("580.lua")) == otherLua)
        #expect(try AutomaticCompatibility.state(paths: paths).jobs[580] == otherJob)
        #expect(try AutomaticAchievements.state(paths: paths).jobs[580] == otherAchievement)
        let undo = try #require(journal.records().first { $0.reason == "还原 \(backup.reason)" })
        try install(680)
        try service.restoreBackup(undo)
        let undone = try service.configSnapshot().0
        #expect(!undone.apps.contains(480)); #expect(undone.apps.contains(580) && undone.apps.contains(680))
        #expect(!FileStore.fm.fileExists(atPath: paths.lua.appendingPathComponent("480.lua").path))
    }

    @Test func batchAllowsRestoringOnlyOneGame() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try install(480); try install(580)
        try service.batch([game(480), game(580)], action: .remove)
        let backup = try #require(journal.records().first { $0.libraryAppIDs?.count == 2 })
        try service.restoreBackup(backup, appIDs: [480])
        #expect(try service.configSnapshot().0.apps.contains(480))
        #expect(try !service.configSnapshot().0.apps.contains(580))
        #expect(!FileStore.fm.fileExists(atPath: paths.lua.appendingPathComponent("580.lua").path))
        #expect(throws: (any Error).self) { try service.restoreBackup(backup, appIDs: [680]) }
    }

    @Test func disabledGameRestoresDisabledAndRemovesNewActiveCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try install(480); try service.setEnabled(game(480), enabled: false)
        let backup = try remove(480)
        try install(480); try install(580)
        try service.restoreBackup(backup)
        #expect(try !game(480).enabled); #expect(try game(580).enabled)
        #expect(FileStore.fm.fileExists(atPath: paths.disabled.appendingPathComponent("480.lua").path))
        #expect(!FileStore.fm.fileExists(atPath: paths.lua.appendingPathComponent("480.lua").path))
    }

    @Test func legacyRemovalAndConfigOnlyNewRemovalAreScoped() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try install(480)
        var legacy = try remove(480); legacy.libraryAppIDs = nil
        let decoded = try JSONDecoder().decode(BackupRecord.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.libraryAppIDs == nil)
        try install(580); try service.restoreBackup(decoded)
        #expect(try game(480).enabled && game(580).enabled)
        try FileStore.fm.removeItem(at: paths.lua.appendingPathComponent("480.lua"))
        let backup = try remove(480)
        try service.restoreBackup(backup)
        #expect(try game(480).enabled && game(580).enabled)
        var ambiguous = backup; ambiguous.libraryAppIDs = nil
        #expect(throws: (any Error).self) { try service.restoreBackup(ambiguous) }
    }

    @Test func checksumAndOwnershipConflictsLeaveCurrentStateUntouched() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try install(480, extra: "addappid(490)\n")
        let backup = try remove(480)
        try install(580, extra: "addappid(490)\n")
        let before = try FileStore.read(paths.config)
        #expect(throws: (any Error).self) { try service.restoreBackup(backup) }
        #expect(try FileStore.read(paths.config) == before)
        let file = try #require(backup.files.first { $0.existed })
        try FileStore.write(Data("corrupt".utf8), to: paths.backups.appendingPathComponent(backup.id).appendingPathComponent(file.stored))
        #expect(throws: (any Error).self) { try service.restoreBackup(backup) }
        #expect(try FileStore.read(paths.config) == before)
        #expect(throws: (any Error).self) { try journal.restore(backup, allowedRoots: [root]) }
    }
}
