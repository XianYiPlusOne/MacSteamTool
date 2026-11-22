import Foundation
import Testing
@testable import FluentSteam
@testable import FluentCore

@Suite @MainActor struct GameRemovalFlowTests {
    func fixture() throws -> (URL, AppModel, GameSaveBackup) {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RemovalFlow-\(UUID().uuidString)")
        let model = AppModel(fixtureHome: root); model.preferences.autoMetadata = false
        let source = model.paths.steam.appendingPathComponent("userdata/123/480/remote")
        try FileStore.write(Data("progress".utf8), to: source.appendingPathComponent("save.dat"))
        let directory = root.appendingPathComponent("Backup")
        let count = try Saves.backup(source, to: directory)
        let backup = GameSaveBackup(appID: 480, source: source, directory: directory, fileCount: count, reason: "before-uninstall")
        try SaveManagerStore.recordBackup(backup, paths: model.paths)
        let key = String(repeating: "ab", count: 32)
        model.libraryInfoFetch = { id in AppInfo(id: id, dictionary: ["common": ["oslist": "windows"], "depots": ["481": ["manifests": ["public": ["gid": "123"]]]]]) }
        model.libraryKeyFetch = { _ in [481: key] }
        return (root, model, backup)
    }
    @Test func reimportOffersBackupOnlyAfterCommitAndDeclineDoesNotRestore() async throws {
        let (root, model, backup) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        model.addToLibrary(480, dlc: false); await model.operation?.value
        #expect(model.saveRecoveryRequest == nil)
        model.commitImport(); await model.operation?.value
        #expect(model.saveRecoveryRequest?.backups.first?.id == backup.id)
        model.deferSaveRecovery(false)
        #expect(model.saveRecoveryRequest == nil)
        #expect(try FileStore.text(URL(fileURLWithPath: backup.source).appendingPathComponent("save.dat")) == "progress")
    }
    @Test func restoringLibraryOffersSaveBackupAndDeferredChoicePersists() async throws {
        let (root, model, backup) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        try model.service.perform(model.service.plan([ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))]))
        let game = try #require(SteamLibrary.games(model.paths).first { $0.id == 480 })
        try model.service.remove(game)
        let record = try #require(FileTransaction(backupRoot: model.paths.backups).records().first { $0.libraryAppIDs == [480] })
        model.restore(record); await model.operation?.value
        #expect(model.saveRecoveryRequest?.backups.first?.id == backup.id)
        model.deferSaveRecovery(true)
        #expect(try SaveManagerStore.load(paths: model.paths).pendingReinstallRestores == [480])
        model.remindSaveRecoveryIfReady(); #expect(model.saveRecoveryRequest == nil)
        try FileStore.write(Data("\"AppState\" { \"appid\" \"480\" \"installdir\" \"Game480\" \"StateFlags\" \"4\" }".utf8), to: model.paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf"))
        try FileStore.mkdir(model.paths.steam.appendingPathComponent("steamapps/common/Game480"))
        model.refresh()
        #expect(model.saveRecoveryRequest?.backups.first?.id == backup.id)
    }
    @Test func removeRequestsChoiceAndEntryOnlyPreservesSaveFiles() async throws {
        let (root, model, backup) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        try model.service.perform(model.service.plan([ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))]))
        let title = "Spacewar"
        let metadata = GameMetadata(id: 480, name: title, image: "https://shared.fastly.steamstatic.com/steam/apps/480/header.jpg")
        try FileStore.json(metadata, to: model.paths.cache.appendingPathComponent("Metadata/schinese-480.json"))
        model.refresh()
        await model.metadataTask?.value
        let game = try #require(model.games.first { $0.id == 480 })
        let before = try FileStore.read(model.paths.config)
        model.remove(game)
        #expect(model.removalRequest != nil)
        #expect(try FileStore.read(model.paths.config) == before)
        model.confirmGameRemoval(deleteFiles: false); await model.operation?.value
        #expect(!model.games.contains { $0.id == 480 })
        #expect(FileStore.fm.fileExists(atPath: backup.source))
        #expect(try SaveManagerStore.load(paths: model.paths).backups.contains { $0.id == backup.id })
        await model.metadataTask?.value
        _ = try CacheMaintenance.clear(paths: model.paths)
        let restarted = AppModel(fixtureHome: root)
        restarted.preferences.autoMetadata = false
        restarted.refresh()
        await restarted.metadataTask?.value
        let row = try #require(restarted.managedSaveGames.first { $0.id == 480 })
        #expect(row.name == title)
        #expect(row.image == metadata.image)
        #expect(row.backupCount == 1)
    }
}
