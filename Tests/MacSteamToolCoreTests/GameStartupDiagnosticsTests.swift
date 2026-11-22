import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct GameStartupDiagnosticsTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var game: InstalledGame { InstalledGame(id: 101, name: "Fixture", library: root, folder: root.appendingPathComponent("steamapps/common/Fixture"), buildID: "1", bytes: 0, depots: [:]) }
        var prefix: URL { root.appendingPathComponent("steamapps/compatdata/101/pfx") }
        var info: URL { game.folder.appendingPathComponent("Fixture_Data/app.info") }
        var log: URL { prefix.appendingPathComponent("drive_c/users/steamuser/AppData/LocalLow/Company/Fixture/Player.log") }
        init() throws { try FileStore.write(Data("Company\nFixture\n".utf8), to: info); try FileStore.mkdir(prefix) }
        func clean() { try? FileStore.fm.removeItem(at: root) }
    }
    @Test func reportsFailureRecoveryAndOnlyRecognizedEvidence() {
        let failure = GameStartupDiagnostics.parse("[Steamworks.NET] SteamAPI_Init() failed. password=private\n[AchievementTracker] SteamManager.Initialized = False\n")
        #expect(failure.0 == .failed); #expect(!failure.1.joined().contains("private"))
        #expect(GameStartupDiagnostics.parse("SteamManager.Initialized = False\nSteamManager.Initialized = True").0 == .initialized)
        #expect(GameStartupDiagnostics.parse("SteamManager.Initialized = True\nSteamAPI_Init() failed").0 == .failed)
        #expect(GameStartupDiagnostics.parse("No error; 21 achievements").0 == .unknown)
    }
    @Test func targetedLogDiscoveryAndBoundedLargeLog() throws {
        let f = try Fixture(); defer { f.clean() }
        let payload = "SteamManager.Initialized = True\n" + String(repeating: "unrelated log\n", count: 100000) + "SteamManager.Initialized = False\n"
        try FileStore.write(Data(payload.utf8), to: f.log)
        let before = try FileStore.read(f.log)
        let report = GameStartupDiagnostics.inspect(f.game, home: f.root)
        #expect(report.status == .failed); #expect(report.log?.resolvingSymlinksInPath() == f.log.resolvingSymlinksInPath()); #expect(report.modifiedAt != nil)
        #expect(report.observations == ["SteamManager.Initialized = True", "SteamManager.Initialized = False"])
        #expect(try FileStore.read(f.log) == before)
    }
    @Test func absentAndUnrecognizedLogsAreNotReportedAsFailures() throws {
        let f = try Fixture(); defer { f.clean() }
        #expect(GameStartupDiagnostics.inspect(f.game, home: f.root).status == .unavailable)
        try FileStore.write(Data("A game with no Steam diagnostic text".utf8), to: f.log)
        #expect(GameStartupDiagnostics.inspect(f.game, home: f.root).status == .unknown)
    }
    @Test func metadataTraversalAndLogSymlinkEscapeAreRejected() throws {
        let f = try Fixture(); defer { f.clean() }
        try FileStore.write(Data("../Company\nFixture\n".utf8), to: f.info)
        try FileStore.write(Data("SteamManager.Initialized = True".utf8), to: f.log)
        #expect(GameStartupDiagnostics.inspect(f.game, home: f.root).status == .unavailable)
        try FileStore.write(Data("Company\nFixture\n".utf8), to: f.info)
        let outside = f.root.appendingPathComponent("private.log")
        try FileStore.write(Data("SteamManager.Initialized = True".utf8), to: outside)
        try FileStore.fm.removeItem(at: f.log)
        try FileStore.fm.createSymbolicLink(at: f.log, withDestinationURL: outside)
        #expect(GameStartupDiagnostics.inspect(f.game, home: f.root).status == .unavailable)
    }
    @Test func nativeUnityMetadataUsesSelectedHomeLogs() throws {
        let f = try Fixture(); defer { f.clean() }
        try FileStore.fm.removeItem(at: f.prefix)
        let native = f.root.appendingPathComponent("Library/Logs/Company/Fixture/Player.log")
        try FileStore.write(Data("SteamManager.Initialized = True".utf8), to: native)
        #expect(GameStartupDiagnostics.inspect(f.game, home: f.root).log == native)
    }
}
