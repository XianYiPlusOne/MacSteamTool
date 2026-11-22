import Foundation
import Testing
@testable import MacSteamTool
@testable import MacSteamToolCore

@Suite @MainActor struct AutomaticLibraryFlowTests {
    let key = String(repeating: "ab", count: 32)
    func fixture() throws -> (URL, AppModel) {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentAutomatic-\(UUID().uuidString)")
        try FileStore.mkdir(root)
        let model = AppModel(fixtureHome: root); model.preferences.autoMetadata = false
        model.libraryPackageFallbacks = { _ in [] }
        model.libraryInfoFetch = { id in AppInfo(id: id, dictionary: ["common": ["name": "Fixture", "oslist": "windows"], "depots": ["481": ["manifests": ["public": ["gid": "123"]]], "482": ["manifests": ["public": ["gid": "124"]]]]]) }
        return (root, model)
    }
    @Test func pinnedPreviewCanContinueAfterSteamVerification() async throws {
        let (root, model) = try fixture()
        defer { try? FileStore.fm.removeItem(at: root) }
        let app = 2852190
        let depot = 2852191
        model.libraryInfoFetch = { id in
            AppInfo(id: id, dictionary: ["common": ["oslist": "windows"], "depots": [
                String(depot): ["manifests": ["public": ["gid": "123"]]]
            ]])
        }
        model.libraryKeyFetch = { _ in [:] }
        model.remotePackageFetch = { _, _, _ in
            let lua = """
            addappid(\(app))
            addappid(\(depot), 1, "\(key)")
            setManifestid(\(depot), "123", 0)
            """
            return [ImportFile(name: "\(app).lua", data: Data(lua.utf8))]
        }
        model.libraryPackageFallbacks = { _ in [("Fixture fallback", { Issue.record("Unexpected fallback"); return [] })] }
        model.addToLibrary(app, dlc: false)
        await model.operation?.value
        #expect(model.pendingImport?.verificationDepots == [depot])
        model.authorizedRepairFetch = { id, depots, _ in
            #expect(id == app && depots == [depot])
            let json = try JSONSerialization.data(withJSONObject: ["ok": true, "appID": app,
                "depots": [["id": depot, "owner": app, "sourceApp": app, "key": key, "result": "OK", "manifest": "123"]]])
            return try JSONDecoder().decode(SteamEngineResponse.self, from: json)
        }
        model.repairAuthorizedContent()
        await model.operation?.value
        #expect(model.pendingImport?.complete == true)
        #expect(model.pendingImport?.verificationDepots.isEmpty == true)
        #expect(model.pendingImport?.plan.documents.first?.pins.first?.active == true)
    }
    @Test func progressModalAppearsSynchronouslyAndKeepsFullLog() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.libraryKeyFetch = { _ in [481: key] }
        model.remotePackageFetch = { _, _, _ in throw AppFailure("Fixture remote offline") }
        model.addToLibrary(480, dlc: false)
        #expect(model.busy); #expect(model.importWorkflowPresented)
        #expect(model.importActivity?.appID == 480)
        let original = model.operation
        model.addToLibrary(490, dlc: false)
        #expect(model.importActivity?.appID == 480)
        for i in 0..<180 { model.recordImportProgress("Detailed check \(i)") }
        await original?.value
        #expect(model.importActivity == nil)
        #expect(model.pendingImport?.checkLog.contains { $0.contains("Detailed check 0") } == true)
        #expect((model.pendingImport?.checkLog.count ?? 0) > 180)
        #expect(model.pendingImport?.checkLog.contains { $0.contains("Fixture remote offline") } == true)
        #expect(model.pendingImport?.content.first?.name == "Fixture")
        #expect(model.pendingImport?.content.first?.missingDepots == [482])
        model.cancelImport(); #expect(!model.importWorkflowPresented)
    }
    @Test func failureAndCancellationLeaveReviewableModal() async throws {
        for cancelled in [false, true] {
            let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
            model.libraryKeyFetch = { _ in
                if cancelled { throw CancellationError() }
                throw AppFailure("Fixture cache offline")
            }
            model.remotePackageFetch = { _, _, _ in throw AppFailure("Fixture remote offline") }
            model.addToLibrary(480, dlc: false); await model.operation?.value
            #expect(model.importActivity?.finished == true)
            #expect(model.importActivity?.failed == !cancelled)
            #expect(model.importWorkflowPresented); #expect(!model.busy)
            #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
            model.closeImportWorkflow(); #expect(!model.importWorkflowPresented)
        }
    }
    @Test func ownedGameUsesSteamNavigationWhileClientIsRunning() async throws {
        let (root, model) = try fixture()
        defer { try? FileStore.fm.removeItem(at: root) }
        var pages: [String] = []
        await model.refreshSteamAfterImport(appID: 2852190, clientRunning: false) { pages.append($0) }
        #expect(pages.isEmpty)
        await model.refreshSteamAfterImport(appID: 2852190, clientRunning: true) { pages.append($0) }
        #expect(pages == ["steam://nav/games/details/2852190"])
        #expect(!model.needsRestart)
    }

    @Test func completeContentWaitsForPreviewConfirmation() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        var reads = 0
        model.libraryKeyFetch = { refresh in #expect(!refresh); reads += 1; return [481: key, 482: key] }
        model.remotePackageFetch = { _, _, _ in Issue.record("Complete local content must not fetch remote"); return [] }
        model.addToLibrary(480, dlc: true); await model.operation?.value
        #expect(model.message == nil); #expect(model.pendingImport != nil); #expect(!model.needsRestart)
        #expect(model.pendingImport?.complete == true)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
        #expect(model.pendingImport?.checkLog.isEmpty == false)
        model.commitImport(); await model.operation?.value
        #expect(model.pendingImport == nil); #expect(!model.needsRestart)
        #expect(model.eventLog.contains { $0.contains("下次启动 Steam") })
        #expect(model.eventLog.contains { $0.contains("已入库") })
        #expect(model.games.first { $0.id == 480 }?.enabled == true)
        let snapshot = try FileStore.read(model.paths.config), backups = model.backups.count
        model.addToLibrary(480, dlc: true); await model.operation?.value
        #expect(reads == 1); #expect(model.backups.count == backups)
        #expect(try FileStore.read(model.paths.config) == snapshot)
    }
    @Test func incompleteContentCannotBeCommitted() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.libraryKeyFetch = { _ in [481: key] }
        model.remotePackageFetch = { _, _, _ in throw AppFailure("Unavailable") }
        model.addToLibrary(480, dlc: false); await model.operation?.value
        #expect(model.message == nil); #expect(!model.needsRestart)
        #expect(model.pendingImport?.plan.warnings.contains { $0.contains("482") } == true)
        #expect(model.eventLog.contains { $0.contains("尚未入库") })
        #expect(!model.eventLog.contains { $0.contains("添加到游戏库 · 完成") })
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path)); #expect(model.games.isEmpty)
        model.commitImport(); await model.operation?.value
        #expect(model.pendingImport != nil); #expect(model.games.isEmpty)
        #expect(model.message?.detail.contains("Library unchanged") == true)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
        #expect(model.backups.isEmpty); #expect(!model.needsRestart)
    }
    @Test func totalFailureAndCancellationNeverWriteLibrary() async throws {
        for cancelled in [false, true] {
            let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
            var remoteCalls = 0
            model.libraryKeyFetch = { _ in if cancelled { throw CancellationError() }; throw AppFailure("No keys") }
            model.remotePackageFetch = { _, _, _ in remoteCalls += 1; throw AppFailure("No remote package") }
            model.addToLibrary(480, dlc: false); await model.operation?.value
            #expect(model.pendingImport == nil); #expect(model.games.isEmpty)
            #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path)); #expect(model.backups.isEmpty)
            #expect((model.message != nil) == !cancelled); #expect(remoteCalls == (cancelled ? 0 : 1))
        }
    }
    @Test func existingDisabledLuaIsNotOverwrittenWithoutPreview() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let original = "addappid(480) -- Custom\n-- Keep my notes\n"
        try FileStore.write(Data(original.utf8), to: model.paths.disabled.appendingPathComponent("480.lua"))
        model.refresh()
        model.libraryKeyFetch = { _ in [481: key, 482: key] }
        model.addToLibrary(480, dlc: true); await model.operation?.value
        #expect(model.message == nil); #expect(model.pendingImport != nil)
        #expect(try FileStore.text(model.paths.disabled.appendingPathComponent("480.lua")) == original)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
        model.cancelImport()
        #expect(model.pendingImport == nil)
        #expect(model.eventLog.first?.contains("已取消入库，未写入游戏库") == true)
        #expect(!model.eventLog.contains { $0.contains("添加到游戏库 · 完成") })
    }
    @Test func changedRuntimeWhileResolvingNeverCommitsStaleScope() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = model.paths.steam.appendingPathComponent("config/config.vdf")
        let config = Data("\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" {} } } }".utf8)
        try FileStore.write(config, to: file)
        model.libraryKeyFetch = { _ in
            try FileStore.write(SteamCompatibility.edit(config, appID: 480, tool: "notproton-1.2.3"), to: file)
            return [481: key, 482: key]
        }
        model.addToLibrary(480, dlc: true); await model.operation?.value
        #expect(model.message?.detail.contains("运行设置已变化") == true)
        #expect(model.pendingImport == nil); #expect(model.games.isEmpty)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
    }
    @Test func runtimeChangedAfterPreviewBlocksCommit() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.libraryKeyFetch = { _ in [481: key, 482: key] }
        model.addToLibrary(480, dlc: false); await model.operation?.value
        #expect(model.pendingImport?.complete == true)
        let manifest = model.paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf")
        try FileStore.write(Data(#""AppState" { "appid" "480" "UserConfig" { "BetaKey" "beta" } }"#.utf8), to: manifest)
        model.commitImport(); await model.operation?.value
        #expect(model.message?.detail.contains("Runtime settings changed") == true || model.message?.detail.contains("runtime settings changed") == true)
        #expect(model.pendingImport != nil); #expect(model.games.isEmpty)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
        #expect(model.backups.isEmpty); #expect(!model.needsRestart)
    }

    @Test func incompleteReimportPreservesDisabledGame() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let original = "addappid(480)\naddappid(481,1,\"\(key)\")\naddappid(482,1,\"\(key)\")\n"
        let file = model.paths.disabled.appendingPathComponent("480.lua")
        try FileStore.write(Data(original.utf8), to: file)
        model.refresh()
        model.libraryKeyFetch = { _ in [481: key] }
        model.remotePackageFetch = { _, _, _ in throw AppFailure("Unavailable") }
        model.addToLibrary(480, dlc: false); await model.operation?.value
        #expect(model.pendingImport?.complete == false)
        model.commitImport(); await model.operation?.value
        #expect(try FileStore.text(file) == original)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.lua.appendingPathComponent("480.lua").path))
        #expect(!FileStore.fm.fileExists(atPath: model.paths.config.path))
        #expect(model.backups.isEmpty); #expect(!model.needsRestart)
    }

}
