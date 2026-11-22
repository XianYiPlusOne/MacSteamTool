import Foundation
import Testing
@testable import MacSteamToolCore

struct AutomaticCompatibilityTests {
    let id = 3531160
    let key = String(repeating: "a", count: 64)
    var info: AppInfo { AppInfo(id: id, dictionary: [
        "common": ["oslist": "windows,macos"], "depots": [
            "3531161": ["config": ["oslist": "windows,linux"], "manifests": ["public": ["gid": "645640092798702039"]]],
            "3531162": ["config": ["oslist": "macos"], "manifests": ["public": ["gid": "4634975929384023034"]]],
            "3531171": ["dlcappid": "3531170", "config": ["oslist": "macos"], "manifests": ["public": ["gid": "123"]]]
        ]]) }
    func fixture() throws -> AppPaths {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("AutoCompat-\(UUID().uuidString)")
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        try FileStore.write(SteamCompatibilityTests().fixture, to: paths.steam.appendingPathComponent("config/config.vdf"))
        try FileStore.write(Data(#"""
        "compatibilitytools" { "compat_tools" {
          "notproton-26.3" { "display_name" "CrossOver 26.3" "from_oslist" "windows" "to_oslist" "macos" }
          "notproton-25.0" { "display_name" "CrossOver 25.0" "from_oslist" "windows" "to_oslist" "macos" }
        } }
        """#.utf8), to: paths.steam.appendingPathComponent("compatibilitytools.d/test/compatibilitytool.vdf"))
        return paths
    }
    func clean(_ paths: AppPaths) { try? FileStore.fm.removeItem(at: paths.data.deletingLastPathComponent()) }
    func add(_ paths: AppPaths, mac: Bool = false) throws {
        let text = "addappid(\(id))\naddappid(3531161, 1, \"\(key)\")\n" + (mac ? "addappid(3531162, 1, \"\(key)\")\n" : "")
        let service = LibraryService(paths: paths)
        try service.perform(service.plan([ImportFile(name: "\(id).lua", data: Data(text.utf8))]))
    }
    func bytes(_ paths: AppPaths) throws -> Data { try FileStore.read(paths.steam.appendingPathComponent("config/config.vdf")) }

    @Test func contentPlatformClassificationIsConservative() {
        #expect(AutomaticCompatibility.assess(info: info, available: [3531161]) == .windowsOnly)
        #expect(AutomaticCompatibility.assess(info: info, available: [3531161, 3531162]) == .nativeAvailable)
        #expect(AutomaticCompatibility.assess(info: info, available: [3531162]) == .nativeAvailable)
        #expect(AutomaticCompatibility.assess(info: info, available: [id, 3531171]) == .unknown)
        #expect(AutomaticCompatibility.assess(info: info, available: [3531161, 777]) == .unknown)
        #expect(AutomaticCompatibility.assess(info: info, available: []) == .unknown)
        var shared = info; shared.depots[0].os = "all"
        #expect(AutomaticCompatibility.assess(info: shared, available: [3531161]) == .nativeAvailable)
        shared.platforms = ["windows"]
        #expect(AutomaticCompatibility.assess(info: shared, available: [3531161]) == .windowsOnly)
        shared.platforms = []
        #expect(AutomaticCompatibility.assess(info: shared, available: [3531161]) == .unknown)
        var unpublished = info; unpublished.depots[1].manifest = ""
        #expect(AutomaticCompatibility.assess(info: unpublished, available: [3531161, 3531162]) == .unknown)
    }
    @Test func importQueuesWhileSteamRunsThenAppliesAndRestores() async throws {
        let p = try fixture(); defer { clean(p) }; let original = try bytes(p)
        try add(p)
        #expect(try AutomaticCompatibility.state(paths: p).jobs[id] != nil)
        let deferred = try await AutomaticCompatibility.process(paths: p, steamRunning: { true }) { _ in info }
        #expect(deferred.waitingForSteam == [id]); #expect(try bytes(p) == original)
        // New process: read durable queue, reuse decision without requesting metadata.
        let applied = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in throw AppFailure("unexpected query") }
        #expect(applied.applied == [id]); #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
        #expect(try SteamCompatibility.mapping(bytes(p), appID: id)?.string("name") == "notproton-26.3")
        #expect(try SteamCompatibility.mapping(bytes(p), appID: 481) == SteamCompatibility.mapping(original, appID: 481))
        #expect(try SteamCompatibility.globalTool(bytes(p)) == "global-tool")
        let after = try bytes(p)
        _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in info }
        #expect(try bytes(p) == after)
        let tx = FileTransaction(backupRoot: p.data.appendingPathComponent("CompatibilityBackups"))
        let backup = try #require(tx.records().first { $0.files.contains { $0.original == p.steam.appendingPathComponent("config/config.vdf").path } })
        try tx.restore(backup, allowedRoots: [p.data.deletingLastPathComponent()])
        #expect(try bytes(p) == original)
        #expect(try AutomaticCompatibility.state(paths: p).jobs[id]?.decision == .windowsOnly)
    }
    @Test func nativeContentAndManualOverridesArePreserved() async throws {
        let p = try fixture(); defer { clean(p) }; let original = try bytes(p)
        try add(p, mac: true)
        let result = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in info }
        #expect(result.applied.isEmpty); #expect(try bytes(p) == original)
        #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
        // An existing explicit Steam choice (including an empty name) wins.
        let manual = try SteamCompatibility.edit(original, appID: id, tool: "other-runtime")
        try FileStore.write(manual, to: p.steam.appendingPathComponent("config/config.vdf"))
        try add(p)
        _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in throw AppFailure("must not query manual entry") }
        #expect(try bytes(p) == manual); #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
        // Choosing native/default in MacSteamTool leaves a durable manual preference.
        let change = try AutomaticCompatibility.manualChange(paths: p, appID: id)
        try FileStore.write(change.data, to: change.url)
        try FileStore.write(original, to: p.steam.appendingPathComponent("config/config.vdf"))
        try add(p)
        #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
        #expect(try bytes(p) == original)
    }
    @Test func missingToolOrOfflineMetadataStaysPending() async throws {
        let p = try fixture(); defer { clean(p) }; let original = try bytes(p)
        try add(p)
        let offline = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in throw AppFailure("offline") }
        #expect(offline.unresolved == [id]); #expect(try bytes(p) == original)
        try FileStore.fm.removeItem(at: p.steam.appendingPathComponent("compatibilitytools.d"))
        let missing = try await AutomaticCompatibility.process(paths: p, force: true, steamRunning: { false }) { _ in info }
        #expect(missing.waitingForTool == [id]); #expect(try bytes(p) == original)
        #expect(try AutomaticCompatibility.state(paths: p).jobs[id]?.decision == .windowsOnly)
    }
    @Test func disableRemoveAndMidRequestEditsCannotApplyStaleChoices() async throws {
        let p = try fixture(); defer { clean(p) }; let original = try bytes(p)
        try add(p)
        _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in
            let game = try #require(try SteamLibrary.games(p).first { $0.id == id })
            try LibraryService(paths: p).setEnabled(game, enabled: false)
            return info
        }
        #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty); #expect(try bytes(p) == original)
        try add(p)
        _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in
            try add(p, mac: true)
            return info
        }
        #expect(try bytes(p) == original)
        _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in info }
        #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
        let game = try #require(try SteamLibrary.games(p).first { $0.id == id })
        try LibraryService(paths: p).remove(game)
        #expect(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
    }
    @Test func steamStartingAtCommitKeepsConfigAndQueue() async throws {
        let p = try fixture(); defer { clean(p) }; let original = try bytes(p)
        try add(p)
        _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { true }) { _ in info }
        var checks = 0
        do {
            _ = try await AutomaticCompatibility.process(paths: p, steamRunning: { checks += 1; return checks >= 3 }) { _ in info }
            Issue.record("Expected Steam-start race to refuse write")
        } catch { #expect(error.localizedDescription.contains("Steam")) }
        #expect(try bytes(p) == original)
        #expect(try AutomaticCompatibility.state(paths: p).jobs[id]?.decision == .windowsOnly)
    }
    @Test func toolPreferenceAndSteamRootsStayScoped() throws {
        let p = try fixture(); defer { clean(p) }
        let tools = try SteamCompatibility.tools(paths: p)
        #expect(try AutomaticCompatibility.preferredTool(tools, config: bytes(p)) == "notproton-26.3")
        let global = Data(String(decoding: try bytes(p), as: UTF8.self).replacingOccurrences(of: "global-tool", with: "notproton-25.0").utf8)
        #expect(try AutomaticCompatibility.preferredTool(tools, config: global) == "notproton-25.0")
        var other = p; other.steam = p.steam.appendingPathComponent("other")
        #expect(AutomaticCompatibility.file(p) != AutomaticCompatibility.file(other))
        try add(p)
        #expect(try AutomaticCompatibility.state(paths: other).jobs.isEmpty)
    }
    @Test func freshSteamAndCachedPlatformMetadataDoNotRequireNetwork() async throws {
        let p = try fixture(); defer { clean(p) }
        try add(p)
        try FileStore.fm.removeItem(at: p.steam.appendingPathComponent("config/config.vdf"))
        let report = try await AutomaticCompatibility.process(paths: p, steamRunning: { false }) { _ in throw AppFailure("must not fetch yet") }
        #expect(report.unresolved == [id]); #expect(try AutomaticCompatibility.state(paths: p).jobs[id] != nil)
        let cache = p.cache.appendingPathComponent("Metadata")
        try FileStore.json(info, to: cache.appendingPathComponent("appinfo-\(id).json"))
        let cached = try await SteamAPI(cache: cache).compatibilityInfo(id)
        #expect(cached.platforms == info.platforms)
        #expect(AutomaticCompatibility.assess(info: cached, available: [3531161]) == .windowsOnly)
    }
}
