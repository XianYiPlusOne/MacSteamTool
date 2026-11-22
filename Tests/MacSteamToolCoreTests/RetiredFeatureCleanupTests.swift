import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct RetiredFeatureCleanupTests {
    private let label = "dev.fluentsteam.mac.trainer-agent"
    private func fixture() throws -> (URL, AppPaths) {
        let home = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentRemoval-\(UUID())")
        try FileStore.mkdir(home)
        return (home, AppPaths(home: home))
    }
    private func plist(_ home: URL) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private func agent(_ home: URL) throws {
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/fixture/retired-helper"]], format: .xml, options: 0), to: plist(home))
    }
    @Test func removesOnlyRetiredSettingsAndAgentAndSignalsOwnedSessions() throws {
        let (home, paths) = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        var preferences = Preferences(); preferences.theme = "dark"; preferences.manifestSource = "hub"; preferences.luaPath = home.appendingPathComponent("CustomLua").path
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        record["trainers"] = [["executable": home.appendingPathComponent("Downloads/tool.exe").path]]
        record["independentTrainerMonitor"] = true; record["futureSetting"] = ["preserved": true]
        try FileStore.write(JSONSerialization.data(withJSONObject: record), to: paths.settings)
        try agent(home)
        let otherAgent = home.appendingPathComponent("Library/LaunchAgents/another.plist")
        let sentinels = [paths.steam.appendingPathComponent("userdata/12345/480/save.bin"), paths.data.appendingPathComponent("Downloads/tool.exe"), otherAgent]
        for file in sentinels { try FileStore.write(Data("keep".utf8), to: file) }
        let session = paths.data.appendingPathComponent("TrainerSessions/\(UUID())"), stop = session.appendingPathComponent("stop")
        try FileStore.json(["stop": WineLaunch.windowsPath(stop.path)], to: session.appendingPathComponent("config.json"))
        var calls: [[String]] = []
        try RetiredFeatureCleanup.run(home: home, paths: paths) { args in calls.append(args); return 0 }
        #expect(calls.count == 2); #expect(calls.map { $0[0] } == ["print", "bootout"])
        #expect(calls.allSatisfy { $0.count == 2 && $0[1].hasSuffix("/\(label)") })
        #expect(!FileStore.fm.fileExists(atPath: plist(home).path)); #expect(FileStore.fm.fileExists(atPath: stop.path))
        for file in sentinels { #expect(try FileStore.text(file) == "keep") }
        let saved = try #require(JSONSerialization.jsonObject(with: FileStore.read(paths.settings)) as? [String: Any])
        record.removeValue(forKey: "trainers"); record.removeValue(forKey: "independentTrainerMonitor")
        #expect(NSDictionary(dictionary: record).isEqual(to: saved))
        let loaded = try FileStore.decode(Preferences.self, at: paths.settings)
        #expect(loaded.theme == "dark"); #expect(loaded.manifestSource == "hub"); #expect(loaded.luaPath == preferences.luaPath)
        let bytes = try FileStore.read(paths.settings)
        try RetiredFeatureCleanup.run(home: home, paths: paths) { _ in 113 }
        #expect(try FileStore.read(paths.settings) == bytes)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        #expect(encoded["trainers"] == nil); #expect(encoded["independentTrainerMonitor"] == nil)
    }
    @Test func stopsLoadedAgentEvenWhenPlistMissingAndDoesNotCreateSettings() throws {
        let (home, paths) = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        var calls: [[String]] = []
        try RetiredFeatureCleanup.run(home: home, paths: paths) { calls.append($0); return 0 }
        #expect(calls.map { $0[0] } == ["print", "bootout"])
        #expect(!FileStore.fm.fileExists(atPath: paths.settings.path))
    }
    @Test func failedBootoutRetainsPlistForRetry() throws {
        let (home, paths) = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        try agent(home)
        #expect(throws: (any Error).self) { try RetiredFeatureCleanup.run(home: home, paths: paths) { $0[0] == "print" ? 0 : 5 } }
        #expect(FileStore.fm.fileExists(atPath: plist(home).path))
        try RetiredFeatureCleanup.run(home: home, paths: paths) { _ in 113 }
        #expect(!FileStore.fm.fileExists(atPath: plist(home).path))
    }
    @Test func corruptSettingsRetainedButObsoleteAgentStillStopped() throws {
        let (home, paths) = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        try FileStore.write(Data("invalid-json".utf8), to: paths.settings); try agent(home)
        var calls: [[String]] = []
        #expect(throws: (any Error).self) { try RetiredFeatureCleanup.run(home: home, paths: paths) { calls.append($0); return 0 } }
        #expect(calls.map { $0[0] } == ["print", "bootout"])
        #expect(try FileStore.text(paths.settings) == "invalid-json"); #expect(!FileStore.fm.fileExists(atPath: plist(home).path))
    }
    @Test func ignoresLinkedSessionsAndRefusesUnrelatedPlist() throws {
        let (home, paths) = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        let external = home.appendingPathComponent("external"), sessions = paths.data.appendingPathComponent("TrainerSessions")
        try FileStore.mkdir(external); try FileStore.mkdir(sessions)
        try FileStore.fm.createSymbolicLink(at: sessions.appendingPathComponent(UUID().uuidString), withDestinationURL: external)
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: ["Label": "unrelated"], format: .xml, options: 0), to: plist(home))
        var calls = 0
        #expect(throws: (any Error).self) { try RetiredFeatureCleanup.run(home: home, paths: paths) { _ in calls += 1; return 0 } }
        #expect(calls == 0); #expect(try FileStore.fm.contentsOfDirectory(atPath: external.path).isEmpty)
        #expect(FileStore.fm.fileExists(atPath: plist(home).path))
    }
    @Test func winePathConversionRejectsInvalidPathsAndPreservesUnicode() throws {
        #expect(throws: (any Error).self) { try WineLaunch.windowsPath("relative.exe") }
        #expect(throws: (any Error).self) { try WineLaunch.windowsPath("/tmp/a\\b.exe") }
        #expect(throws: (any Error).self) { try WineLaunch.windowsPath("/tmp/a\0.exe") }
        #expect(try WineLaunch.windowsPath("/tmp/中文 folder/tool.exe").hasSuffix("\\中文 folder\\tool.exe"))
    }
}
