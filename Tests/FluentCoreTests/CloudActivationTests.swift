import Foundation
import Testing
@testable import FluentCore

struct CloudActivationTests {
    func fixture() throws -> AppPaths {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CloudActivation-\(UUID().uuidString)")
        let p = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        try FileStore.write(Data("Apps:\n  - 480 # Main\n  - 481 # DLC @480\n  - 482 # Another\n".utf8), to: p.config)
        return p
    }
    func clean(_ p: AppPaths) { try? FileStore.fm.removeItem(at: p.data.deletingLastPathComponent()) }
    @Test func defaultsFollowMainGamesAndExcludeWithoutEnablingStatistics() throws {
        let p = try fixture(); defer { clean(p) }
        var c = CloudConfiguration.localDefaults(paths: p)
        #expect(c.enabled && c.automaticApps && c.provider == .folder)
        #expect(!c.syncAchievements && !c.syncPlaytime && c.statsApps.isEmpty)
        #expect(try c.selectedApps(paths: p) == [480, 482])
        c.excludedApps = "482"; try c.save(paths: p)
        #expect(try CloudConfiguration.load(paths: p).selectedApps(paths: p) == [480])
        try FileStore.write(Data("Apps:\n  - 483 # Newly enabled\n".utf8), to: p.config)
        #expect(try c.selectedApps(paths: p) == [483])
    }
    @Test func legacyManualConfigAndUnknownProviderFieldsArePreserved() throws {
        let p = try fixture(); defer { clean(p) }
        let url = p.data.appendingPathComponent("CloudRedirect/config.json")
        try FileStore.write(Data(#"{"enabled":true,"apps":[480],"provider":"webdav","token_paths":{"webdav":"fixture-secret-file"},"future_setting":42}"#.utf8), to: url)
        let c = try CloudConfiguration.load(paths: p)
        #expect(!c.automaticApps && c.provider == .webdav)
        #expect(try c.selectedApps(paths: p) == [480]); try c.save(paths: p)
        let j = try JSONSerialization.jsonObject(with: FileStore.read(url)) as! [String: Any]
        #expect(j["future_setting"] as? Int == 42)
        #expect((j["token_paths"] as? [String: String])?["webdav"] == "fixture-secret-file")
    }
    @Test func verifiedBackupPrecedesActivationAndNeverChangesSaves() throws {
        let p = try fixture(); defer { clean(p) }
        let c = CloudConfiguration.localDefaults(paths: p)
        let source = p.steam.appendingPathComponent("userdata/1/480/remote/save.bin")
        let other = p.steam.appendingPathComponent("userdata/1/999/remote/save.bin")
        let bytes = Data([0, 1, 255, 0, 35]); try FileStore.write(bytes, to: source); try FileStore.write(Data("other".utf8), to: other)
        let inventory = CloudSaveInventory(apps: [480, 482], files: [.init(appID: 480, path: source.path)])
        let backup = try #require(try CloudActivation.save(c, inventory: inventory, paths: p, steamRunning: { false }))
        #expect(try FileStore.read(source) == bytes); #expect(try FileStore.text(other) == "other")
        #expect(try FileStore.read(backup.appendingPathComponent("0.save")) == bytes)
        #expect(!FileStore.fm.fileExists(atPath: backup.appendingPathComponent(".INCOMPLETE").path))
        #expect(try CloudConfiguration.load(paths: p).enabled)
    }
    @Test func runningSteamOrIncompleteScopeCannotActivate() throws {
        let p = try fixture(); defer { clean(p) }
        let c = CloudConfiguration.localDefaults(paths: p)
        #expect(throws: (any Error).self) { try CloudActivation.save(c, inventory: nil, paths: p, steamRunning: { true }) }
        #expect(throws: (any Error).self) { try CloudActivation.save(c, inventory: .init(apps: [480], files: []), paths: p, steamRunning: { false }) }
        #expect(!FileStore.fm.fileExists(atPath: p.data.appendingPathComponent("CloudRedirect/config.json").path))
    }
    @Test func concurrentSteamStartAndSourceChangesPreventConfigWrite() throws {
        let p = try fixture(); defer { clean(p) }
        let c = CloudConfiguration.localDefaults(paths: p), inventory = CloudSaveInventory(apps: [480, 482], files: [])
        var checks = 0
        #expect(throws: (any Error).self) { try CloudActivation.save(c, inventory: inventory, paths: p, steamRunning: { checks += 1; return checks >= 3 }) }
        #expect(!FileStore.fm.fileExists(atPath: p.data.appendingPathComponent("CloudRedirect/config.json").path))
        checks = 0
        #expect(throws: (any Error).self) { try CloudActivation.save(c, inventory: inventory, paths: p, steamRunning: {
            checks += 1
            if checks == 3 { try? FileStore.write(Data("Apps:\n  - 999\n".utf8), to: p.config) }
            return false
        }) }
        #expect(!FileStore.fm.fileExists(atPath: p.data.appendingPathComponent("CloudRedirect/config.json").path))
    }
    @Test func symlinkSaveAndInvalidExclusionsAreRejected() throws {
        let p = try fixture(); defer { clean(p) }
        var c = CloudConfiguration.localDefaults(paths: p)
        c.excludedApps = "wrong"; #expect(throws: (any Error).self) { try c.save(paths: p) }
        c.excludedApps = ""
        let source = p.data.appendingPathComponent("original"), link = p.data.appendingPathComponent("linked")
        try FileStore.write(Data("save".utf8), to: source); try FileStore.fm.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try CloudActivation.save(c, inventory: .init(apps: [480, 482], files: [.init(appID: 480, path: link.path)]), paths: p, steamRunning: { false }) }
        #expect(try FileStore.text(source) == "save")
    }
    @Test func runtimeStatusRequiresCurrentProcessAndMatchingConfiguration() throws {
        let p = try fixture(); defer { clean(p) }
        try CloudConfiguration.localDefaults(paths: p).save(paths: p)
        let config = p.data.appendingPathComponent("CloudRedirect/config.json"), status = p.data.appendingPathComponent("CloudRedirect/runtime-status.json")
        let sha = FileStore.hash(try FileStore.read(config))
        try FileStore.write(Data("{\"pid\":123,\"cloudReady\":true,\"cloudConfigSHA256\":\"\(sha)\",\"cloudFailures\":2}".utf8), to: status)
        #expect(CloudRuntimeStatus.current(paths: p, pids: []) == nil)
        let current = try #require(CloudRuntimeStatus.current(paths: p, pids: [123]))
        #expect(!current.needsRestart(paths: p)); #expect(current.cloudFailures == 2)
        try FileStore.write(Data("{}".utf8), to: config); #expect(current.needsRestart(paths: p))
        try FileStore.write(Data(#"{"pid":123}"#.utf8), to: status)
        #expect(try #require(CloudRuntimeStatus.current(paths: p, pids: [123])).needsRestart(paths: p))
    }
}
