import Foundation
import Testing
@testable import MacSteamToolCore

struct SaveManagementTests {
    private func fixture() throws -> AppPaths {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SaveManager-\(UUID().uuidString)")
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        try FileStore.write(Data("Apps:\n  - 900001 # Alpha\n  - 900002 # Beta\n  - 900003 # DLC @900001\n".utf8), to: paths.config)
        return paths
    }
    private func clean(_ paths: AppPaths) { try? FileStore.fm.removeItem(at: paths.data.deletingLastPathComponent()) }
    private func location(_ id: Int, _ path: String) -> SaveLocation { .init(appID: id, kind: "Fixture", url: URL(fileURLWithPath: path)) }

    @Test func catalogGroupsByGameWithoutMixingAccountsOrDuplicateFolders() {
        var state = SaveManagerState(); state.games["900004"] = .init()
        state.backups = [.init(appID: 900005, source: URL(fileURLWithPath: "/tmp/source"), directory: URL(fileURLWithPath: "/tmp/backup"), fileCount: 1, reason: "manual")]
        let catalog = SaveManagement.catalog(games: [.init(id: 900001, name: "Alpha"), .init(id: 900002, name: "Beta")], locations: [location(900001, "/tmp/account1/remote"), location(900001, "/tmp/account1/remote"), location(900001, "/tmp/account2/remote"), location(900006, "/tmp/orphan"), location(-1, "/tmp/invalid")], state: state)
        #expect(Set(catalog.map(\.id)) == [900001, 900002, 900004, 900005, 900006])
        #expect(catalog.first { $0.id == 900001 }?.locations.count == 2)
        #expect(catalog.first { $0.id == 900002 }?.locations.isEmpty == true)
        #expect(catalog.first { $0.id == 900005 }?.backupCount == 1)
        #expect(SaveManagement.filtered(catalog, query: " aLPha ", onlyWithSaves: true).map(\.id) == [900001])
        #expect(SaveManagement.filtered(catalog, query: "900005", onlyWithSaves: true).count == 1)
        #expect(SaveManagement.filtered(catalog, query: "Beta", onlyWithSaves: true).isEmpty)
    }

    @Test func removedLibraryEntriesKeepLocalizedMetadataWithTheirSaves() throws {
        let paths = try fixture()
        defer { clean(paths) }
        let library = LibraryService(paths: paths)
        let a = Game(id: 900001, name: "Alpha"), b = Game(id: 900002, name: "Beta")
        let reference = "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/900001/head/header.jpg"
        try SaveGameMetadataStore.remember(paths: paths, localized: [.init(id: a.id, name: "阿尔法", image: reference)])
        try library.remove(a)
        try library.batch([b], action: .remove)
        // Placeholder imports and a missing image must not overwrite earlier good values.
        try SaveGameMetadataStore.remember(paths: paths, games: [.init(id: a.id, name: "App 900001")],
                                          localized: [.init(id: a.id, name: "Alpha")], language: "english")
        _ = try CacheMaintenance.clear(paths: paths)
        let records = try SaveGameMetadataStore.remember(paths: paths)
        let catalog = SaveManagement.catalog(games: [], locations: [location(a.id, "/tmp/a"), location(b.id, "/tmp/b")],
                                            state: .init(), metadata: records)
        #expect(catalog.first { $0.id == a.id }?.name == "阿尔法")
        #expect(catalog.first { $0.id == a.id }?.image == reference)
        #expect(catalog.first { $0.id == b.id }?.name == "Beta")
        #expect(records[a.id]?.displayName(language: "english") == "Alpha")
        #expect(SaveManagement.catalog(games: [], locations: [], state: .init(), metadata: records).isEmpty)
    }

    @Test func savingPreferencesPreservesOtherGamesAndNeverChangesSaveFiles() throws {
        let paths = try fixture(); defer { clean(paths) }
        let a = paths.data.appendingPathComponent("fixture-a"), b = paths.data.appendingPathComponent("fixture-b")
        try FileStore.write(Data("original-a".utf8), to: a.appendingPathComponent("save.dat"))
        try FileStore.write(Data("original-b".utf8), to: b.appendingPathComponent("save.dat"))
        var optionA = GameSaveOptions(); optionA.customFolders = [a.path, a.path]; optionA.backupDirectory = paths.data.appendingPathComponent("backup-a").path
        var optionB = GameSaveOptions(); optionB.customFolders = [b.path]
        try SaveManagerStore.saveOptions(optionA, appID: 900001, paths: paths)
        try SaveManagerStore.saveOptions(optionB, appID: 900002, paths: paths)
        var state = try SaveManagerStore.load(paths: paths)
        #expect(state.options(for: 900001).customFolders == [a.path]); #expect(state.options(for: 900002) == optionB)
        optionA.customFolders = []; try SaveManagerStore.saveOptions(optionA, appID: 900001, paths: paths)
        state = try SaveManagerStore.load(paths: paths)
        #expect(state.options(for: 900002) == optionB)
        #expect(try FileStore.text(a.appendingPathComponent("save.dat")) == "original-a")
        #expect(try FileStore.text(b.appendingPathComponent("save.dat")) == "original-b")
    }

    @Test func invalidPreferencesAndUnknownVersionsDoNotOverwriteState() throws {
        let paths = try fixture(); defer { clean(paths) }
        try SaveManagerStore.saveOptions(.init(), appID: 900001, paths: paths)
        let file = paths.data.appendingPathComponent("SaveManager/state.json"), before = try FileStore.read(paths.data.appendingPathComponent("SaveManager/state.json"))
        for path in ["relative/folder", "/", "/tmp/..", "/tmp/invalid\npath"] {
            var options = GameSaveOptions(); options.customFolders = [path]
            #expect(throws: (any Error).self) { try SaveManagerStore.saveOptions(options, appID: 900001, paths: paths) }
        }
        #expect(throws: (any Error).self) { try SaveManagerStore.saveOptions(.init(), appID: 0, paths: paths) }
        #expect(try FileStore.read(file) == before)
        var future = SaveManagerState(); future.version = 2; try FileStore.json(future, to: file)
        let futureBytes = try FileStore.read(file)
        #expect(throws: (any Error).self) { try SaveManagerStore.load(paths: paths) }
        #expect(throws: (any Error).self) { try SaveManagerStore.saveOptions(.init(), appID: 900001, paths: paths) }
        #expect(try FileStore.read(file) == futureBytes)
    }

    @Test func customFoldersRequireExistingDirectoriesAndRejectSymlinks() throws {
        let paths = try fixture(); defer { clean(paths) }
        let folder = paths.data.appendingPathComponent("custom"), file = paths.data.appendingPathComponent("file"), link = paths.data.appendingPathComponent("link")
        try FileStore.mkdir(folder); try FileStore.write(Data("data".utf8), to: file)
        try FileStore.fm.createSymbolicLink(at: link, withDestinationURL: folder)
        var options = GameSaveOptions(); options.customFolders = [folder.path, file.path, link.path, paths.data.appendingPathComponent("missing").path, "/", "/tmp/.."]
        var state = SaveManagerState(); state.games["900001"] = options
        #expect(SaveManagement.customLocations(state).map { $0.url.path } == [folder.path])
    }

    @Test func historyIsPerGameNewestFirstAndDoesNotDuplicateBackupPaths() throws {
        let paths = try fixture(); defer { clean(paths) }
        let source = paths.data.appendingPathComponent("source")
        var old = GameSaveBackup(appID: 900001, source: source, directory: paths.data.appendingPathComponent("older"), fileCount: 1, reason: "manual")
        old.created = Date(timeIntervalSince1970: 10)
        var new = GameSaveBackup(appID: 900001, source: source, directory: paths.data.appendingPathComponent("newer"), fileCount: 2, reason: "before-clear")
        new.created = Date(timeIntervalSince1970: 20)
        let other = GameSaveBackup(appID: 900002, source: source, directory: paths.data.appendingPathComponent("other"), fileCount: 3, reason: "manual")
        for record in [old, new, other, new] { try SaveManagerStore.recordBackup(record, paths: paths) }
        let state = try SaveManagerStore.load(paths: paths)
        #expect(state.backups.count == 3)
        #expect(state.backups(for: 900001).map(\.id) == [new.id, old.id])
        #expect(state.backups(for: 900002).map(\.id) == [other.id])
    }

    @Test func syntheticBackupAndRestoreLeaveSecondGameUntouched() throws {
        let paths = try fixture(); defer { clean(paths) }
        let source = paths.data.appendingPathComponent("game-a"), other = paths.data.appendingPathComponent("game-b/slot.dat"), backup = paths.data.appendingPathComponent("export")
        try FileStore.write(Data("first-version".utf8), to: source.appendingPathComponent("slot.dat")); try FileStore.write(Data("untouched".utf8), to: other)
        let count = try Saves.backup(source, to: backup)
        try SaveManagerStore.recordBackup(.init(appID: 900001, source: source, directory: backup, fileCount: count, reason: "manual"), paths: paths)
        #expect(try Saves.verifyBackup(backup).count == 1)
        try FileStore.write(Data("second-version".utf8), to: source.appendingPathComponent("slot.dat"))
        let result = try Saves.restore(backup, to: source, backupRoot: paths.data.appendingPathComponent("rollback"))
        let previous = try #require(result.previousBackup)
        try SaveManagerStore.recordBackup(.init(appID: 900001, source: source, directory: previous, fileCount: try Saves.verifyBackup(previous).count, reason: "before-restore"), paths: paths)
        #expect(try FileStore.text(source.appendingPathComponent("slot.dat")) == "first-version")
        #expect(try FileStore.text(previous.appendingPathComponent("slot.dat")) == "second-version")
        #expect(try FileStore.text(other) == "untouched")
        #expect(try SaveManagerStore.load(paths: paths).backups(for: 900001).count == 2)
    }
}
