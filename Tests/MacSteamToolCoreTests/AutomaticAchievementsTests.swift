import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct AutomaticAchievementsTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var paths: AppPaths { AppPaths(home: root) }
        init() throws { try FileStore.write(Data("Apps:\n  - 101\n  - 102 # DLC @101\n  - 103\n".utf8), to: paths.config) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func schema(_ id: Int) throws { try FileStore.write(Data([0] + Array(String(id).utf8) + [0, 8]), to: paths.steam.appendingPathComponent("appcache/stats/UserGameStatsSchema_\(id).bin")) }
        func queue(_ ids: [Int], removing: [Int] = []) throws {
            let config = try MacSteamConfig.parse(FileStore.text(paths.config))
            if let change = try AutomaticAchievements.queueChange(paths: paths, config: config, apps: ids, removing: removing) {
                try FileTransaction(backupRoot: paths.backups).apply([(change.url, change.data)], reason: "fixture", expectations: [change.url: change.expected])
            }
        }
    }
    @Test func onlyQueuedMainGamesAndNoSteamNoNetwork() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try await AutomaticAchievements.process(paths: f.paths, steamRunning: { false }) { _ in Issue.record("unexpected network") }
        #expect(!FileStore.fm.fileExists(atPath: AutomaticAchievements.file(f.paths).path))
        try f.queue([101, 102])
        #expect(Set(try AutomaticAchievements.state(paths: f.paths).jobs.keys) == [101])
        let report = try await AutomaticAchievements.process(paths: f.paths, steamRunning: { false }) { _ in Issue.record("Steam is stopped") }
        #expect(report.waitingForLogin == [101]); #expect(!AchievementRepair.enabled(appID: 101, paths: f.paths))
    }
    @Test func fetchWhileOnlineActivateOnlyAfterExitAndPreserveOptOut() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.queue([101])
        let config = f.paths.data.appendingPathComponent("CloudRedirect/config.json")
        let before = Data(#"{"enabled":true,"provider":"folder","token_paths":{"folder":"/fixture"},"stats_apps":[],"sync_playtime":false}"#.utf8)
        try FileStore.write(before, to: config)
        let ready = try await AutomaticAchievements.process(paths: f.paths, steamRunning: { true }) { try f.schema($0) }
        #expect(ready.waitingForExit == [101]); #expect(try FileStore.read(config) == before)
        let done = try await AutomaticAchievements.process(paths: f.paths, steamRunning: { false }) { _ in Issue.record("cached schema should be reused") }
        #expect(done.applied == [101]); #expect(AchievementRepair.enabled(appID: 101, paths: f.paths))
        #expect(!AchievementRepair.enabled(appID: 103, paths: f.paths))
        try FileStore.write(before, to: config) // User later disables statistics.
        try f.queue([101])
        #expect(try AutomaticAchievements.state(paths: f.paths).jobs.isEmpty)
        #expect(!AchievementRepair.enabled(appID: 101, paths: f.paths))
    }
    @Test func failureBackoffAndRemovalDuringFetch() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.queue([101])
        let now = Date()
        let failed = try await AutomaticAchievements.process(paths: f.paths, now: now, steamRunning: { true }) { _ in throw AppFailure("offline") }
        #expect(failed.failures[101] == "offline")
        _ = try await AutomaticAchievements.process(paths: f.paths, now: now.addingTimeInterval(10), steamRunning: { true }) { _ in Issue.record("backoff ignored") }
        let cancelled = try await AutomaticAchievements.process(paths: f.paths, force: true, steamRunning: { true }) { id in
            try f.queue([], removing: [id]); try f.schema(id)
        }
        #expect(cancelled.waitingForExit.isEmpty); #expect(try AutomaticAchievements.state(paths: f.paths).jobs.isEmpty)
    }
    @Test func concurrentSteamStartAndPlaytimeScopeGuard() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.queue([101]); try f.schema(101)
        var checks = 0
        let raced = try await AutomaticAchievements.process(paths: f.paths, steamRunning: { checks += 1; return checks > 1 }) { _ in }
        #expect(raced.applied.isEmpty); #expect(raced.failures[101] != nil)
        #expect(!AchievementRepair.enabled(appID: 101, paths: f.paths))
        let config = f.paths.data.appendingPathComponent("CloudRedirect/config.json")
        let original = Data(#"{"sync_achievements":true,"sync_playtime":true,"stats_apps":[103]}"#.utf8)
        try FileStore.write(original, to: config)
        let guarded = try await AutomaticAchievements.process(paths: f.paths, steamRunning: { false }) { _ in }
        #expect(guarded.applied.isEmpty); #expect(guarded.failures[101] != nil)
        #expect(try FileStore.read(config) == original)
    }
    @Test func queueScopeAndInvalidSchema() throws {
        let f = try Fixture(); defer { f.clean() }; try f.queue([101]); try f.schema(102)
        try FileStore.write(FileStore.read(f.paths.steam.appendingPathComponent("appcache/stats/UserGameStatsSchema_102.bin")), to: f.paths.steam.appendingPathComponent("appcache/stats/UserGameStatsSchema_101.bin"))
        #expect(!AchievementRepair.schemaAvailable(appID: 101, paths: f.paths))
        var other = f.paths; other.steam = f.root.appendingPathComponent("OtherSteam")
        #expect(try AutomaticAchievements.state(paths: other).jobs.isEmpty)
    }
}
