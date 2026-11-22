import Foundation
import Testing
@testable import MacSteamTool
@testable import MacSteamToolCore

@Suite @MainActor struct ConnectedFlowTests {
    func fixture() throws -> (URL, AppModel) {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentConnected-\(UUID().uuidString)")
        try FileStore.mkdir(root); let model = AppModel(fixtureHome: root)
        model.preferences.autoMetadata = false
        return (root, model)
    }
    func settle(_ model: AppModel) async { await model.operation?.value }
    func until(_ test: () -> Bool) async throws {
        for _ in 0..<150 { if test() { return }; try await Task.sleep(for: .milliseconds(30)) }
        throw AppFailure("Flow did not reach the expected state")
    }
    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    func manifest() -> Data {
        func varint(_ value: UInt64) -> [UInt8] { var n=value, out:[UInt8]=[]; while n>=128 { out.append(UInt8(n&127)|128); n >>= 7 }; return out+[UInt8(n)] }
        func u32(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: n >> (8*$0)) } }
        let meta=[UInt8(8)]+varint(481)+[16]+varint(123)+[72]+varint(0x2144df1c)
        return Data(u32(0x71f617d0)+u32(0)+u32(0x1f4812be)+u32(UInt32(meta.count))+meta+u32(0x1b81b817)+u32(0)+u32(0x32c415ab))
    }
    @Test func automaticRemoteFallbackCommitBatchAndReload() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        var preferences = Preferences(); preferences.remotePackageMode = "direct"
        #expect(try RemoteLuaPackage.source(preferences).template == RemoteLuaPackage.defaultTemplate)
        model.preferences.remotePackageMode = "direct"
        model.libraryInfoFetch = { id in
            AppInfo(id: id, dictionary: ["common": ["oslist": "windows"], "depots": [
                "481": ["manifests": ["public": ["gid": "123"]]],
                "482": ["manifests": ["public": ["gid": "124"]]]
            ]])
        }
        model.libraryKeyFetch = { _ in throw AppFailure("No local keys") }
        let zip = root.appendingPathComponent("remote.zip")
        let key = String(repeating: "ab", count: 32)
        try ArchiveIO.export([ImportFile(name: "480.lua", data: Data("addappid(480) -- Connected fixture\naddappid(481, 1, \"\(key)\")\n".utf8))], to: zip)
        let bytes = try FileStore.read(zip)
        model.remotePackageFetch = { id, preferences, engine in
            #expect(id == 480); #expect(try RemoteLuaPackage.source(preferences).template == RemoteLuaPackage.defaultTemplate)
            return try await RemoteLuaPackage.extract(bytes, appID: id, engine: engine)
        }
        model.libraryPackageFallbacks = { id in
            [("Fixture secondary", {
                let lua = "addappid(\(id))\naddappid(482, 1, \"\(key)\")\n"
                return [ImportFile(name: "\(id).lua", data: Data(lua.utf8))]
            })]
        }
        model.addToLibrary(480, dlc: true); await settle(model)
        #expect(model.message == nil)
        #expect(model.pendingImport?.complete == true); #expect(model.games.isEmpty)
        #expect(model.pendingImport?.checkLog.contains { $0.contains("Fixture secondary") } == true)
        model.commitImport(); await settle(model)
        #expect(model.pendingImport == nil); #expect(model.games.first?.enabled == true)
        let imported = try FileStore.read(model.paths.lua.appendingPathComponent("480.lua"))
        model.batchLibrary(model.games, action: .disable); await settle(model)
        #expect(model.games.first?.enabled == false)
        #expect(try FileStore.read(model.paths.disabled.appendingPathComponent("480.lua")) == imported)
        model.batchLibrary(model.games, action: .enable); await settle(model)
        #expect(model.games.first?.enabled == true)
        model.batchLibrary(model.games, action: .remove)
        #expect(model.removalRequest != nil)
        model.confirmGameRemoval(deleteFiles: false); await settle(model)
        #expect(model.games.isEmpty); #expect(!model.backups.isEmpty)
        let reloaded = AppModel(fixtureHome: root); reloaded.refresh(); #expect(reloaded.games.isEmpty)
    }
    @Test func hubNotFoundContinuesThenValidResponseWritesAndRejectedKeyStops() async throws {
        let (root, model) = try fixture(); defer { model.stopManifestMonitor(); try? FileStore.fm.removeItem(at: root) }
        let log = model.paths.steam.appendingPathComponent("logs/content_log.txt")
        try FileStore.write(Data(), to: log)
        model.games = [Game(id: 480, name: "Fixture", enabled: true)]
        model.hubCredentialLoad = { ManifestHubCredential(key: "test-only", saved: Date()) }
        var requested: [String] = []
        let valid = manifest()
        model.manifestFetch = { _, manifest, source in
            requested.append(source)
            if manifest == "1" { throw ManifestHubFailure.notFound }
            if manifest == "2" { throw ManifestHubFailure.rejectedKey }
            return valid
        }
        model.startManifestMonitor(source: "hub")
        try append("BYldRequestDepotManifest(App: 480, Depot: 481, Manifest: 1)\n", to: log)
        try await until { model.hubMonitorFailed == 1 }
        #expect(model.hubMonitorRunning)
        try append("BYldRequestDepotManifest(App: 480, Depot: 481, Manifest: 123)\n", to: log)
        try await until { model.hubMonitorCompleted == 1 }
        #expect(try FileStore.read(model.paths.depotCache.appendingPathComponent("481_123.manifest")) == valid)
        model.startManifestMonitor(source: "code")
        #expect(model.monitorRunning); #expect(!model.hubMonitorRunning)
        model.startManifestMonitor(source: "hub"); #expect(!model.monitorRunning); #expect(model.hubMonitorRunning)
        try append("BYldRequestDepotManifest(App: 480, Depot: 481, Manifest: 2)\n", to: log)
        try await until { !model.hubMonitorRunning }
        #expect(model.hubMonitorFailed == 1); #expect(requested == ["hub", "hub", "hub"])
    }
    @Test func failedManifestCanBeRetriedByANewSteamLogLine() async throws {
        let (root, model) = try fixture(); defer { model.stopManifestMonitor(); try? FileStore.fm.removeItem(at: root) }
        let log = model.paths.steam.appendingPathComponent("logs/content_log.txt")
        try FileStore.write(Data(), to: log); model.games = [Game(id: 480, name: "Fixture", enabled: true)]
        model.hubCredentialLoad = { ManifestHubCredential(key: "synthetic", saved: Date()) }
        let valid = manifest(); var attempts = 0
        model.manifestFetch = { _, _, _ in attempts += 1; if attempts == 1 { throw AppFailure("Temporary transport failure") }; return valid }
        model.startManifestMonitor(source: "hub")
        let line = "BYldRequestDepotManifest(App: 480, Depot: 481, Manifest: 123)\n"
        try append(line, to: log); try await until { model.hubMonitorFailed == 1 }
        #expect(model.hubMonitorRunning)
        try append(line, to: log); try await until { model.hubMonitorCompleted == 1 }
        #expect(attempts == 2); #expect(try FileStore.read(model.paths.depotCache.appendingPathComponent("481_123.manifest")) == valid)
    }
    @Test func requestSkippedBeforeEnableDoesNotSuppressTheLaterRetry() async throws {
        let (root, model) = try fixture(); defer { model.stopManifestMonitor(); try? FileStore.fm.removeItem(at: root) }
        let log = model.paths.steam.appendingPathComponent("logs/content_log.txt")
        try FileStore.write(Data(), to: log); let valid = manifest(); var attempts = 0
        model.manifestFetch = { _, _, _ in attempts += 1; return valid }
        model.startManifestMonitor(source: "code")
        let line = "BYldRequestDepotManifest(App: 480, Depot: 481, Manifest: 123)\n"
        try append(line, to: log); try await Task.sleep(for: .milliseconds(600)); #expect(attempts == 0)
        model.games = [Game(id: 480, name: "Fixture", enabled: true)]
        try append(line, to: log); try await until { model.monitorCompleted == 1 }; #expect(attempts == 1)
    }
    @Test func manualManifestSelectedSourceAndBadPayloadDoesNotWrite() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.preferences.manifestSource = "hub"; let valid = manifest()
        model.manifestFetch = { depot, manifest, source in #expect(source == "hub"); #expect(depot == 481); #expect(manifest == "123"); return valid }
        model.repairManifest(depot: 481, manifest: "123"); await settle(model)
        let target = model.paths.depotCache.appendingPathComponent("481_123.manifest")
        #expect(try FileStore.read(target) == valid)
        model.manifestFetch = { _, _, _ in Data("<html>bad response</html>".utf8) }
        model.repairManifest(depot: 481, manifest: "123"); await settle(model)
        #expect(model.message != nil); #expect(try FileStore.read(target) == valid)
    }
    @Test func bootstrapMigratesRetiredFeatureAndPreservesNavigationAndPreferences() async throws {
        let (root, model) = try fixture(); defer { model.timer?.invalidate(); try? FileStore.fm.removeItem(at: root) }
        var preferences = Preferences(); preferences.autoMetadata = false; preferences.autoRefresh = false; preferences.theme = "dark"; preferences.language = "en"
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        record["trainers"] = "obsolete malformed binding"; record["independentTrainerMonitor"] = true
        try FileStore.write(JSONSerialization.data(withJSONObject: record), to: model.defaults.settings)
        await model.bootstrap()
        #expect(model.message == nil); #expect(model.preferences.theme == "dark"); #expect(model.preferences.language == "en")
        #expect(Page(rawValue: "trainers") == nil)
        #expect(Set(Page.allCases.map(\.rawValue)) == Set(["library", "discover", "manifests", "multiplayer", "offlineTools", "achievements", "saves", "accounts", "runtime", "containers", "settings", "guide"]))
        let saved = try #require(JSONSerialization.jsonObject(with: FileStore.read(model.defaults.settings)) as? [String: Any])
        #expect(saved["trainers"] == nil); #expect(saved["independentTrainerMonitor"] == nil)
    }
    @Test func achievementInvertOnlyChangesDraft() throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.achievements = [Achievement(id: "A", name: "A", detail: "", achieved: false, unlockedAt: 0), Achievement(id: "B", name: "B", detail: "", achieved: true, unlockedAt: 1)]
        model.originalAchievements = model.achievements
        model.invertAchievements(); #expect(model.achievements.map(\.achieved) == [true, false])
        #expect(model.originalAchievements.map(\.achieved) == [false, true]); #expect(model.achievementChanges.count == 2)
        model.busy = true; model.invertAchievements(); #expect(model.achievements.map(\.achieved) == [true, false])
    }
    @Test func achievementEditorScopesDraftAndFailedReadToSelectedGame() async throws {
        let (root, model) = try fixture()
        defer { try? FileStore.fm.removeItem(at: root) }
        let first = Game(id: 101, name: "First")
        let second = Game(id: 202, name: "Second")
        model.openAchievementEditor(for: first)
        model.loadedAchievementApp = first.id
        model.originalAchievements = [Achievement(id: "A", name: "A", detail: "", achieved: false, unlockedAt: 0)]
        model.achievements = model.originalAchievements
        model.invertAchievements()
        model.achievementProgress[first.id] = (0, 1)

        model.openAchievementEditor(for: second)
        #expect(model.achievementGame?.id == second.id)
        #expect(model.loadedAchievementApp == nil)
        #expect(model.achievements.isEmpty && model.originalAchievements.isEmpty)
        #expect(model.achievementChanges.isEmpty)
        #expect(model.achievementProgress[first.id]?.unlocked == 0)
        #expect(model.achievementProgress[second.id] == nil)

        model.readAchievements()
        model.openAchievementEditor(for: first)
        await settle(model)
        #expect(model.achievementGame?.id == second.id)
        #expect(model.loadedAchievementApp == nil && !model.achievementStatus.isEmpty)
        #expect(model.message == nil)
    }
    @Test func loginCompletionPersistsBeforeReplacingAccountAndClearsOldLibrary() throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.onlineAccount = "old"; model.ownedGames = [OwnedGame(id: 480, name: "Old library", type: "game")]
        let result = try JSONDecoder().decode(SteamEngineResponse.self, from: Data(#"{"ok":true,"account":"new","token":"synthetic"}"#.utf8))
        #expect(throws: (any Error).self) { try model.completeOnlineAuthentication(result, persist: { _ in throw AppFailure("Store failed") }) }
        #expect(model.onlineAccount == "old"); #expect(!model.ownedGames.isEmpty)
        try model.completeOnlineAuthentication(result, persist: { credential in #expect(credential.account == "new"); #expect(credential.token == "synthetic") })
        #expect(model.onlineAccount == "new"); #expect(model.ownedGames.isEmpty)
    }
}
