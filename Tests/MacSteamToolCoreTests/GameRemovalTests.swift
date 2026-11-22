import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct GameRemovalTests {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GameRemoval-\(UUID().uuidString)")
    var paths: AppPaths { AppPaths(home: root) }
    var service: LibraryService { LibraryService(paths: paths) }
    func write(_ text: String, _ file: URL) throws { try FileStore.write(Data(text.utf8), to: file) }
    func install(_ id: Int, library: URL? = nil) throws {
        let library = library ?? paths.steam
        try write("\"AppState\" { \"appid\" \"\(id)\" \"installdir\" \"Game\(id)\" \"StateFlags\" \"4\" }", library.appendingPathComponent("steamapps/appmanifest_\(id).acf"))
        try write("game data", library.appendingPathComponent("steamapps/common/Game\(id)/game.exe"))
        try service.perform(service.plan([ImportFile(name: "\(id).lua", data: Data("addappid(\(id))".utf8))]))
    }
    func container(_ id: Int, wine: Bool = false, library: URL? = nil) throws -> GameContainer {
        let c = GameContainer(appID: id, library: library ?? paths.steam, isWine: wine)
        try write("registry", c.prefix.appendingPathComponent("user.reg"))
        try write("registry", c.prefix.appendingPathComponent("system.reg"))
        try write("progress-\(id)", c.prefix.appendingPathComponent("drive_c/users/steamuser/Documents/Game/save.dat"))
        return c
    }
    func plan(_ id: Int = 480) throws -> GameRemovalPlan {
        try GameRemoval.plan(game: #require(SteamLibrary.games(paths).first { $0.id == id }), paths: paths)
    }
    func perform(_ plan: GameRemovalPlan) async throws -> [URL] {
        try await GameRemoval.perform(plan, paths: paths, requireIdle: {}, checkUsage: { _ in }, retire: { try FileStore.fm.removeItem(at: $0) })
    }
    @Test func fullRemovalBacksUpBothBackendsAndSavesAndPreservesOtherGame() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480); try install(580)
        let c = try container(480), w = try container(480, wine: true), other = try container(580)
        let remote = paths.steam.appendingPathComponent("userdata/123/480/remote")
        try write("remote progress", remote.appendingPathComponent("save.dat"))
        let preview = try plan()
        #expect(preview.containers.count == 2)
        #expect(try await perform(preview).isEmpty)
        #expect(!FileStore.fm.fileExists(atPath: c.root.path))
        #expect(!FileStore.fm.fileExists(atPath: w.prefix.path))
        #expect(!FileStore.fm.fileExists(atPath: remote.path))
        #expect(!FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/common/Game480").path))
        #expect(!FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf").path))
        #expect(other.ready)
        #expect(try service.configSnapshot().0.apps == [580])
        let backups = try SaveManagerStore.load(paths: paths).backups(for: 480)
        #expect(backups.count == 3)
        for item in backups { #expect(try Saves.verifyBackup(URL(fileURLWithPath: item.directory)).count > 0) }
        #expect(GameContainers.backups(c, paths: paths).count == 1)
        #expect(GameContainers.backups(w, paths: paths).count == 1)
        let record = try #require(FileTransaction(backupRoot: paths.backups).records().first { $0.libraryAppIDs == [480] })
        try service.restoreBackup(record)
        #expect(try service.configSnapshot().0.apps.contains(480))
        #expect(!FileStore.fm.fileExists(atPath: c.prefix.path))
    }
    @Test func failedSaveBackupNeverDeletesLiveFiles() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480)
        let c = try container(480)
        let documents = c.prefix.appendingPathComponent("drive_c/users/steamuser/Documents")
        try FileStore.fm.createSymbolicLink(at: documents.appendingPathComponent("link"), withDestinationURL: root)
        let before = try FileStore.read(paths.config)
        await #expect(throws: (any Error).self) { try await perform(plan()) }
        #expect(c.ready)
        #expect(try FileStore.read(paths.config) == before)
        #expect(FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/common/Game480/game.exe").path))
    }
    @Test func changedPreviewAndRunningGamePreventDeletion() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480)
        let preview = try plan()
        await #expect(throws: (any Error).self) {
            try await GameRemoval.perform(preview, paths: paths, requireIdle: {}, checkUsage: { _ in throw AppFailure("Running") })
        }
        try write("changed", paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf"))
        await #expect(throws: (any Error).self) { try await perform(preview) }
        #expect(FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/common/Game480/game.exe").path))
    }
    @Test func configFailureRollsBackStagedGameAndSaveDirectories() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480); let c = try container(480)
        let preview = try plan()
        try write("Apps: [480]", paths.config)
        await #expect(throws: (any Error).self) { try await perform(preview) }
        #expect(c.ready)
        #expect(FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/common/Game480/game.exe").path))
        #expect(FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf").path))
        #expect(try !SaveManagerStore.load(paths: paths).backups(for: 480).isEmpty)
    }
    @Test func sharedCustomSaveFolderIsRejected() throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480); try install(580)
        let shared = root.appendingPathComponent("SharedSaves")
        try write("data", shared.appendingPathComponent("save"))
        var options = GameSaveOptions(); options.customFolders = [shared.path]
        try SaveManagerStore.saveOptions(options, appID: 480, paths: paths)
        try SaveManagerStore.saveOptions(options, appID: 580, paths: paths)
        #expect(throws: (any Error).self) { try plan() }
        #expect(FileStore.fm.fileExists(atPath: shared.path))
    }
    @Test func recoveryWaitsForInstallationAndContainerThenUsesNewLibrary() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480); let c = try container(480)
        _ = try await perform(plan())
        let backup = try #require(SaveRecovery.latest(appIDs: [480], paths: paths).first)
        #expect(throws: (any Error).self) { try SaveRecovery.destination(backup, paths: paths) }
        let newLibrary = root.appendingPathComponent("NewLibrary")
        try write("\"libraryfolders\" { \"1\" { \"path\" \"\(newLibrary.path)\" } }", paths.steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        try install(480, library: newLibrary)
        #expect(throws: (any Error).self) { try SaveRecovery.destination(backup, paths: paths) }
        let newContainer = try container(480, library: newLibrary)
        let save = newContainer.prefix.appendingPathComponent("drive_c/users/steamuser/Documents/Game/save.dat")
        try write("new progress", save)
        try await SaveRecovery.restore(backup, paths: paths, requireIdle: {}, checkUsage: { _ in })
        #expect(try FileStore.text(save) == "progress-480")
        #expect(!c.exists)
        let rollback = try #require(SaveManagerStore.load(paths: paths).backups.first { $0.reason == "before-restore" })
        #expect(try FileStore.text(URL(fileURLWithPath: rollback.directory).appendingPathComponent("Game/save.dat")) == "new progress")
        try SaveManagerStore.remindAfterInstall([480], enabled: true, paths: paths)
        #expect(try SaveManagerStore.load(paths: paths).pendingReinstallRestores == [480])
    }
    @Test func corruptedRecoveryBackupLeavesCurrentProgressUntouched() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480); let c = try container(480)
        _ = try await perform(plan())
        let backup = try #require(SaveRecovery.latest(appIDs: [480], paths: paths).first)
        try install(480); _ = try container(480)
        let current = c.prefix.appendingPathComponent("drive_c/users/steamuser/Documents/Game/save.dat")
        try write("current", current)
        try write("corrupt", URL(fileURLWithPath: backup.directory).appendingPathComponent("Game/save.dat"))
        await #expect(throws: (any Error).self) { try await SaveRecovery.restore(backup, paths: paths, requireIdle: {}, checkUsage: { _ in }) }
        #expect(try FileStore.text(current) == "current")
    }
    @Test func registryOnlySavesCanRestoreAFullContainerAfterReinstall() async throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480); let c = try container(480)
        try FileStore.fm.removeItem(at: c.prefix.appendingPathComponent("drive_c/users"))
        try write("registry progress", c.prefix.appendingPathComponent("user.reg"))
        _ = try await perform(plan())
        #expect(try SaveRecovery.latest(appIDs: [480], paths: paths).isEmpty)
        let backup = try #require(GameContainers.removalBackups(appIDs: [480], paths: paths).first)
        await #expect(throws: (any Error).self) { try await SaveRecovery.restoreContainer(backup, paths: paths, requireIdle: {}) }
        let library = root.appendingPathComponent("OtherLibrary")
        try write("\"libraryfolders\" { \"1\" { \"path\" \"\(library.path)\" } }", paths.steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        try install(480, library: library)
        try await SaveRecovery.restoreContainer(backup, paths: paths, requireIdle: {})
        let restored = GameContainer(appID: 480, library: library, isWine: false)
        #expect(restored.ready)
        #expect(try FileStore.text(restored.prefix.appendingPathComponent("user.reg")) == "registry progress")
    }
    @Test func invalidInstallDirectoryCannotRemoveLibraryRoot() throws {
        defer { try? FileStore.fm.removeItem(at: root) }
        try install(480)
        try write("\"AppState\" { \"appid\" \"480\" \"installdir\" \".\" }", paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf"))
        #expect(throws: (any Error).self) { try plan() }
        #expect(FileStore.fm.fileExists(atPath: paths.steam.appendingPathComponent("steamapps/common/Game480/game.exe").path))
    }
}
