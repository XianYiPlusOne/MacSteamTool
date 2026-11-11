import Foundation
import Testing
@testable import FluentSteam
@testable import FluentCore

@Suite @MainActor struct AutomaticLibraryFlowTests {
    let key = String(repeating: "ab", count: 32)
    func fixture() throws -> (URL, AppModel) {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentAutomatic-\(UUID().uuidString)")
        try FileStore.mkdir(root)
        let model = AppModel(fixtureHome: root); model.preferences.autoMetadata = false
        model.libraryInfoFetch = { id in AppInfo(id: id, dictionary: ["common": ["name": "Fixture", "oslist": "windows"], "depots": ["481": ["manifests": ["public": ["gid": "123"]]], "482": ["manifests": ["public": ["gid": "124"]]]]]) }
        return (root, model)
    }
    @Test func completeContentCommitsOnceWithoutPreview() async throws {
        let (root, model) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        var reads = 0
        model.libraryKeyFetch = { refresh in #expect(!refresh); reads += 1; return [481: key, 482: key] }
        model.remotePackageFetch = { _, _, _ in Issue.record("Complete local content must not fetch remote"); return [] }
        model.addToLibrary(480, dlc: true); await model.operation?.value
        #expect(model.message == nil); #expect(model.pendingImport == nil); #expect(model.needsRestart)
        #expect(model.eventLog.contains { $0.contains("已入库：AppID 480") })
        #expect(model.games.first { $0.id == 480 }?.enabled == true)
        let snapshot = try FileStore.read(model.paths.config), backups = model.backups.count
        model.addToLibrary(480, dlc: true); await model.operation?.value
        #expect(reads == 1); #expect(model.backups.count == backups)
        #expect(try FileStore.read(model.paths.config) == snapshot)
    }
    @Test func incompleteContentOnlyPreviewsUntilUserChoosesImport() async throws {
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
        #expect(model.pendingImport == nil); #expect(model.games.first?.enabled == true)
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
}
