import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct DirectoryMigrationTests {
    func fixture() throws -> AppPaths {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Migration-\(UUID().uuidString)")
        try FileStore.mkdir(root)
        return AppPaths(home: root, data: root.appendingPathComponent("Data"))
    }
    func clean(_ p: AppPaths) { try? FileStore.fm.removeItem(at: p.data.deletingLastPathComponent()) }
    @Test func luaChangeAndResetPreserveDisabledFilesAndOriginals() throws {
        let p = try fixture(); defer { clean(p) }
        try FileStore.write(Data("active".utf8), to: p.lua.appendingPathComponent("100.lua"))
        try FileStore.write(Data("disabled".utf8), to: p.disabled.appendingPathComponent("200.lua"))
        try FileStore.write(Data("unrelated".utf8), to: p.lua.appendingPathComponent("keep.txt"))
        var settings = Preferences(); let target = p.data.appendingPathComponent("OtherLua"); settings.luaPath = target.path
        let result = try PreferenceStore.save(settings, defaults: p, migrateLua: true, steamRunning: { false })
        #expect(result?.copied == 2)
        #expect(try FileStore.text(target.appendingPathComponent("Disable/200.lua")) == "disabled")
        #expect(try FileStore.text(p.lua.appendingPathComponent("100.lua")) == "active")
        #expect(!FileStore.fm.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
        try FileStore.write(Data("new".utf8), to: target.appendingPathComponent("300.lua"))
        settings.luaPath = ""
        #expect(try PreferenceStore.save(settings, defaults: p, migrateLua: true, steamRunning: { false })?.copied == 1)
        #expect(try FileStore.text(p.lua.appendingPathComponent("300.lua")) == "new")
    }
    @Test func conflictAndRunningSteamKeepSettingsUnchanged() throws {
        let p = try fixture(); defer { clean(p) }
        try FileStore.json(Preferences(), to: p.settings); let original = try FileStore.read(p.settings)
        try FileStore.write(Data("source".utf8), to: p.lua.appendingPathComponent("100.lua"))
        var settings = Preferences(); let target = p.data.appendingPathComponent("OtherLua"); settings.luaPath = target.path
        try FileStore.write(Data("destination".utf8), to: target.appendingPathComponent("100.lua"))
        #expect(throws: (any Error).self) { try PreferenceStore.save(settings, defaults: p, migrateLua: true, steamRunning: { false }) }
        #expect(try FileStore.read(p.settings) == original)
        #expect(try FileStore.text(target.appendingPathComponent("100.lua")) == "destination")
        #expect(throws: (any Error).self) { try PreferenceStore.save(settings, defaults: p, migrateLua: true, steamRunning: { true }) }
        #expect(try FileStore.read(p.settings) == original)
    }
    @Test func mutationCommitFailureOverlapAndSymlinkDoNotSwitchOrOverwrite() throws {
        let p = try fixture(); defer { clean(p) }
        let source = p.data.appendingPathComponent("Source"), dest = p.data.appendingPathComponent("Dest"), file = source.appendingPathComponent("data")
        try FileStore.write(Data("old".utf8), to: file)
        var count = 0, committed = false
        #expect(throws: (any Error).self) { try DirectoryMigration.apply(from: source, to: dest, selection: .all, lockRoot: p.backups, validate: {
            count += 1; if count == 3 { try FileStore.write(Data("changed".utf8), to: file) }
        }, commit: { committed = true }) }
        #expect(!committed); #expect(!FileStore.fm.fileExists(atPath: dest.appendingPathComponent("data").path))
        #expect(throws: (any Error).self) { try DirectoryMigration.apply(from: source, to: dest, selection: .all, lockRoot: p.backups, commit: { throw AppFailure("commit failure") }) }
        #expect(!FileStore.fm.fileExists(atPath: dest.appendingPathComponent("data").path))
        #expect(throws: (any Error).self) { try DirectoryMigration.apply(from: source, to: source.appendingPathComponent("nested"), selection: .all, lockRoot: p.backups, commit: {}) }
        try FileStore.fm.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: file)
        #expect(throws: (any Error).self) { try DirectoryMigration.apply(from: source, to: dest, selection: .all, lockRoot: p.backups, commit: {}) }
    }
}
