import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct AchievementRepairTests {
    @Test func persistedCompatibilityVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("CloudRedirect/stats/7")
        func section(_ key: String, _ children: [UInt8]) -> [UInt8] { [0] + Array(key.utf8) + [0] + children + [8] }
        func text(_ key: String, _ value: String) -> [UInt8] { [1] + Array(key.utf8) + [0] + Array(value.utf8) + [0] }
        let schema = section("101", section("stats", section("3", section("bits", section("5", text("name", "A")))))) + [8]
        try FileStore.write(Data(schema), to: folder.appendingPathComponent("schemas/101.bin"))
        var times = [UInt32](repeating: 0, count: 32); times[5] = 100
        let record: [String: Any] = ["stats": [["id": 3, "value": 32]], "achievements": [["stat_id": 3, "bits": 32, "unlock_times": times]]]
        try FileStore.write(JSONSerialization.data(withJSONObject: record), to: folder.appendingPathComponent("101.json"))
        let rows = [Achievement(id: "A", name: "A", detail: "", achieved: true, unlockedAt: 100)]
        let changes = [AchievementChange(id: "A", expected: false, achieved: true)]
        try CompatibilityAchievements.verify(root: root, account: 7, appID: 101, rows: rows, changes: changes)
        let delayed = [Achievement(id: "A", name: "A", detail: "", achieved: true, unlockedAt: 99)]
        try CompatibilityAchievements.verify(root: root, account: 7, appID: 101, rows: delayed, changes: changes)
        #expect(throws: Error.self) { try CompatibilityAchievements.verify(root: root, account: 8, appID: 101, rows: rows, changes: changes) }
        #expect(throws: Error.self) { try CompatibilityAchievements.verify(root: root, account: 7, appID: 102, rows: rows, changes: changes) }
        #expect(throws: Error.self) { try CompatibilityAchievements.verify(root: root, account: 7, appID: 101, rows: rows, changes: [.init(id: "A", expected: true, achieved: false)]) }
        try FileStore.write(Data("{}".utf8), to: folder.appendingPathComponent("101.json"))
        #expect(throws: Error.self) { try CompatibilityAchievements.verify(root: root, account: 7, appID: 101, rows: rows, changes: changes) }
        let config = Data(#"{"sync_achievements":true,"stats_apps":[101]}"#.utf8)
        try FileStore.write(config, to: root.appendingPathComponent("CloudRedirect/config.json"))
        let status: [String: Any] = ["pid": 100, "cloudReady": true, "cloudConfigSHA256": FileStore.hash(config)]
        try FileStore.write(JSONSerialization.data(withJSONObject: status), to: root.appendingPathComponent("CloudRedirect/runtime-status.json"))
        #expect(CompatibilityAchievements.active(root: root, appID: 101, runningPIDs: [100]))
        #expect(!CompatibilityAchievements.active(root: root, appID: 102, runningPIDs: [100]))
        #expect(!CompatibilityAchievements.active(root: root, appID: 101, runningPIDs: [101]))
        try FileStore.write(Data(#"{"sync_achievements":false,"stats_apps":[101]}"#.utf8), to: root.appendingPathComponent("CloudRedirect/config.json"))
        #expect(!CompatibilityAchievements.active(root: root, appID: 101, runningPIDs: [100]))
    }
    @Test func sourceValidationAndEditIsolation() throws {
        #expect(try AchievementRepair.sourceID(Data("76561197960265729\n".utf8)) == 76561197960265729)
        for text in ["0", "<html>error</html>", "76561197960265729x", "-76561197960265729"] {
            #expect(throws: Error.self) { try AchievementRepair.sourceID(Data(text.utf8)) }
        }
        var request = AchievementRequest(appID: 101, library: "/fixture/steamclient.dylib", changes: [.init(id: "A", expected: false, achieved: true)])
        request.operation = "schema"; request.schemaSourceSteamID = 76561197960265729
        #expect(throws: Error.self) { try request.validate() }
    }
    @Test func repairPreservesSaveSettingsAndBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        try FileStore.write(Data("Apps:\n  - 101 # Fixture\n  - 102 # DLC @101\n".utf8), to: paths.config)
        let url = paths.data.appendingPathComponent("CloudRedirect/config.json")
        let original = Data(#"{"enabled":true,"automatic_apps":true,"excluded_apps":[110],"provider":"folder","token_paths":{"folder":"/fixture/cloud"},"sync_playtime":false,"stats_apps":[],"unrecognized":{"keep":true}}"#.utf8)
        try FileStore.write(original, to: url)
        #expect(throws: Error.self) { try AchievementRepair.enable(appID: 101, paths: paths) }
        #expect(try FileStore.read(url) == original)
        let schema = paths.steam.appendingPathComponent("appcache/stats/UserGameStatsSchema_101.bin")
        try FileStore.write(Data([0] + Array("101".utf8) + [0, 8]), to: schema)
        try AchievementRepair.enable(appID: 101, paths: paths)
        let data = try FileStore.read(url), edited = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let prior = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for key in prior.keys where key != "stats_apps" { #expect(NSDictionary(dictionary: [key: edited[key]!]).isEqual(to: [key: prior[key]!])) }
        #expect(edited["stats_apps"] as? [Int] == [101]); #expect(edited["sync_achievements"] as? Bool == true)
        #expect(throws: Error.self) { try AchievementRepair.enable(appID: 102, paths: paths) }
        #expect(throws: Error.self) { try AchievementRepair.enable(appID: 103, paths: paths) }
        let count = FileStore.files(paths.backups).count
        try AchievementRepair.enable(appID: 101, paths: paths)
        #expect(FileStore.files(paths.backups).count == count)
        let backup = try #require(FileStore.files(paths.backups).first)
        #expect(try FileStore.read(backup.appendingPathComponent("0.bak")) == original)
    }
}
