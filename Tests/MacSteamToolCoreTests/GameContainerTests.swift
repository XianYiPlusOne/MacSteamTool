import Foundation
import Testing
import Darwin
@testable import MacSteamToolCore

@Suite struct GameContainerTests {
    struct Fixture {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Container test '\(UUID().uuidString)")
        var paths: AppPaths { AppPaths(home: home) }
        var wine: GameContainer { GameContainer(appID: 42, library: paths.steam, isWine: true) }
        var crossOver: GameContainer { GameContainer(appID: 42, library: paths.steam, isWine: false) }
        init() throws {
            try FileStore.mkdir(home)
            try FileStore.write(Data("\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"CompatToolMapping\" { \"0\" { \"name\" \"fluent-proton-free\" } } } } } }".utf8), to: paths.steam.appendingPathComponent("config/config.vdf"))
        }
        func clean() { try? FileStore.fm.removeItem(at: home) }
        func seed(_ container: GameContainer, value: String = "old save") throws {
            for name in ["system.reg", "user.reg", "drive_c/users/steamuser/save.dat"] { try FileStore.write(Data(value.utf8), to: container.prefix.appendingPathComponent(name)) }
        }
        func freeRunner(fail: Bool = false) throws -> ContainerBackend {
            let root = paths.data.appendingPathComponent("FreeRuntime/versions/test")
            for name in ["receipt.json", "bridge/steamclient64.dll", "bridge/steam.exe", "runner/lib/renderers/dxmt/x86_64-windows/d3d11.dll"] { try FileStore.write(Data(), to: root.appendingPathComponent(name)) }
            for (name, source) in [
                ("runner/bin/wineserver", "#!/bin/sh\nexit 0\n"),
                ("runner/lib/wine/x86_64-unix/wine", fail ? "#!/bin/sh\nexit 7\n" : "#!/bin/sh\nprintf 'registry' > \"$WINEPREFIX/system.reg\"\nprintf 'registry' > \"$WINEPREFIX/user.reg\"\nprintf '%s' \"$WINEPREFIX\" > \"$WINEPREFIX/created-in\"\n")
            ] {
                let file = root.appendingPathComponent(name); try FileStore.write(Data(source.utf8), to: file); try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            let tool = FreeRuntime.tool(paths)
            try FileStore.write(Data(root.path.utf8), to: tool.appendingPathComponent("runtime-root"))
            try FileStore.write(Data(), to: tool.appendingPathComponent("prefix-support-ready"))
            try FileStore.write(Data("#!/bin/sh\nexit 0\n".utf8), to: tool.appendingPathComponent("run"))
            try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.appendingPathComponent("run").path)
            try FileStore.write(Data("\"compatibilitytools\" { \"compat_tools\" { \"fluent-proton-free\" { \"display_name\" \"Wine\" \"from_oslist\" \"windows\" \"to_oslist\" \"macos\" } } }".utf8), to: tool.appendingPathComponent("compatibilitytool.vdf"))
            return try #require(GameContainers.backends(paths).first)
        }
    }
    @Test func listsBothBackendsEvenWhenOnlyOneIsSelected() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.seed(f.wine); try f.seed(f.crossOver)
        #expect(GameContainers.all(f.paths).count == 2)
        #expect(SteamLibrary.prefixes(f.paths).count == 1)
        #expect(try GameContainers.selectedTool(appID: 42, paths: f.paths) == FreeRuntime.toolID)
    }
    @Test func createsIsolatedPrefixWithoutOverwritingOtherBackendOrChangingSelection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runner = try f.freeRunner(); try f.seed(f.crossOver)
        let before = try FileStore.read(f.paths.steam.appendingPathComponent("config/config.vdf"))
        try await GameContainers.create(f.wine, backend: runner, paths: f.paths, requireIdle: {})
        #expect(f.wine.ready)
        #expect(try FileStore.text(f.wine.prefix.appendingPathComponent("created-in")).hasPrefix(f.wine.root.path + "/.pfx-creating-"))
        #expect(try FileStore.text(f.crossOver.prefix.appendingPathComponent("user.reg")) == "old save")
        #expect(try FileStore.read(f.paths.steam.appendingPathComponent("config/config.vdf")) == before)
        await #expect(throws: (any Error).self) { try await GameContainers.create(f.wine, backend: runner, paths: f.paths, requireIdle: {}) }
    }
    @Test func failedInitializationDoesNotPublishAnEmptyContainer() async throws {
        let f = try Fixture(); defer { f.clean() }; let runner = try f.freeRunner(fail: true)
        await #expect(throws: (any Error).self) { try await GameContainers.create(f.wine, backend: runner, paths: f.paths, requireIdle: {}) }
        #expect(!f.wine.exists)
        #expect(!FileStore.files(f.wine.root).contains { $0.lastPathComponent.hasPrefix(".pfx-creating-") })
    }
    @Test func backupRestorePreservesSavesLinksAndRunnerRecord() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.seed(f.crossOver)
        try FileStore.mkdir(f.crossOver.prefix.appendingPathComponent("dosdevices"))
        try FileStore.fm.createSymbolicLink(atPath: f.crossOver.prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try FileStore.write(Data("26.3.0.39832\nRosetta\n".utf8), to: f.crossOver.root.appendingPathComponent("notproton-build"))
        let backup = try await GameContainers.backup(f.crossOver, paths: f.paths, requireIdle: {})
        try f.seed(f.crossOver, value: "new save")
        try await GameContainers.restore(backup, to: f.crossOver, paths: f.paths, requireIdle: {})
        #expect(try FileStore.text(f.crossOver.prefix.appendingPathComponent("drive_c/users/steamuser/save.dat")) == "old save")
        #expect(try FileStore.fm.destinationOfSymbolicLink(atPath: f.crossOver.prefix.appendingPathComponent("dosdevices/z:").path) == "/")
        #expect(try FileStore.text(f.crossOver.root.appendingPathComponent("notproton-build")) == "26.3.0.39832\nRosetta\n")
        let copies = GameContainers.backups(f.crossOver, paths: f.paths)
        #expect(copies.count == 2)
        let beforeRestore = try #require(copies.first(where: { $0.id != backup.id }))
        #expect(try FileStore.text(f.paths.data.appendingPathComponent("ContainerBackups/\(beforeRestore.id)/pfx/user.reg")) == "new save")
    }
    @Test func removalIsRecoverableAndNeverDeletesOtherContainerOrGameFiles() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.seed(f.wine); try f.seed(f.crossOver)
        let game = f.paths.steam.appendingPathComponent("steamapps/common/Game/game.exe"); try FileStore.write(Data("game".utf8), to: game)
        let copy = try await GameContainers.remove(f.crossOver, paths: f.paths, requireIdle: {})
        #expect(!f.crossOver.exists); #expect(f.wine.ready); #expect(FileStore.fm.fileExists(atPath: game.path))
        #expect(GameContainers.recoverable(f.paths).map(\.id) == [f.crossOver.id])
        await #expect(throws: (any Error).self) { try await GameContainers.restore(copy, to: f.wine, paths: f.paths, requireIdle: {}) }
        try await GameContainers.restore(copy, to: f.crossOver, paths: f.paths, requireIdle: {})
        #expect(f.crossOver.ready); #expect(GameContainers.recoverable(f.paths).isEmpty)
    }
    @Test func refusesExternalPathsSymlinkRootsAndBusyContainers() async throws {
        let f = try Fixture(); defer { f.clean() }; try f.seed(f.wine)
        let outside = GameContainer(appID: 42, library: f.home, isWine: false)
        #expect(throws: (any Error).self) { try GameContainers.validate(outside, paths: f.paths) }
        let fd = open(f.wine.root.appendingPathComponent(".notproton-prefix.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { flock(fd, LOCK_UN); close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: (any Error).self) { _ = try await GameContainers.remove(f.wine, paths: f.paths, requireIdle: {}) }
        #expect(f.wine.ready)
        let link = GameContainer(appID: 43, library: f.paths.steam, isWine: false)
        try FileStore.fm.createSymbolicLink(at: link.root, withDestinationURL: f.home)
        #expect(throws: (any Error).self) { try GameContainers.validate(link, paths: f.paths) }
    }
    @Test func steamActivityStopsMutationBeforeCreatingOrRemovingFiles() async throws {
        let f = try Fixture(); defer { f.clean() }; let runner = try f.freeRunner()
        let busy: @Sendable () throws -> Void = { throw AppFailure("Steam is running") }
        await #expect(throws: (any Error).self) { try await GameContainers.create(f.wine, backend: runner, paths: f.paths, requireIdle: busy) }
        #expect(!f.wine.exists)
        try f.seed(f.wine)
        await #expect(throws: (any Error).self) { try await GameContainers.remove(f.wine, paths: f.paths, requireIdle: busy) }
        #expect(f.wine.ready); #expect(GameContainers.backups(f.wine, paths: f.paths).isEmpty)
    }
    @Test func crossOverCreationUsesRegisteredBuildAndPreservesWineContainer() async throws {
        let f = try Fixture(); defer { f.clean() }; _ = try f.freeRunner(); try f.seed(f.wine)
        let root = f.paths.notProton.appendingPathComponent("runners/crossover-26.3.0.39832/CrossOver")
        let fake = f.paths.data.appendingPathComponent("FreeRuntime/versions/test/runner")
        try FileStore.mkdir(root.deletingLastPathComponent()); try FileStore.fm.copyItem(at: fake, to: root)
        try FileStore.write(Data("notproton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n".utf8), to: f.paths.notProton.appendingPathComponent("tools"))
        let tool = f.paths.steam.appendingPathComponent("compatibilitytools.d/notproton-26.3")
        try FileStore.write(Data("\"compatibilitytools\" { \"compat_tools\" { \"notproton-26.3\" { \"display_name\" \"CrossOver 26.3\" \"from_oslist\" \"windows\" \"to_oslist\" \"macos\" } } }".utf8), to: tool.appendingPathComponent("compatibilitytool.vdf"))
        let backend = try #require(GameContainers.backends(f.paths).first(where: { !$0.isWine }))
        try await GameContainers.create(f.crossOver, backend: backend, paths: f.paths, requireIdle: {})
        #expect(f.crossOver.ready)
        #expect(try FileStore.text(f.crossOver.root.appendingPathComponent("notproton-build")) == "26.3.0.39832\nRosetta\n")
        #expect(try FileStore.text(f.wine.prefix.appendingPathComponent("user.reg")) == "old save")
        #expect(try GameContainers.backend(for: f.crossOver, paths: f.paths)?.id == backend.id)
    }
    @Test func toolsUseExplicitContainerInsteadOfCurrentlySelectedBackend() async throws {
        let f = try Fixture(); defer { f.clean() }; let backend = try f.freeRunner(); try f.seed(f.crossOver)
        try await GameContainers.create(f.wine, backend: backend, paths: f.paths, requireIdle: {})
        let file = f.paths.steam.appendingPathComponent("config/config.vdf")
        try FileStore.write(SteamCompatibility.edit(FileStore.read(file), appID: 42, tool: "notproton-26.3"), to: file)
        let process = try await GameContainers.launch(f.wine, command: "winecfg", paths: f.paths, requireIdle: {})
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isRunning)
        #expect(try FileStore.text(f.wine.prefix.appendingPathComponent("created-in")) == f.wine.prefix.path)
        #expect(try FileStore.text(f.crossOver.prefix.appendingPathComponent("user.reg")) == "old save")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLUENT_CONTAINER_REAL_WINE_TEST"] == "1"))
    func actualWineCreatesBacksUpAndRestoresOnlyDisposableContainer() async throws {
        let f = try Fixture(); defer { f.clean() }
        let real = try #require(FreeRuntime.installedRoot(AppPaths()))
        _ = try f.freeRunner()
        let runner = f.paths.data.appendingPathComponent("FreeRuntime/versions/test")
        try FileStore.fm.removeItem(at: runner)
        try FileStore.fm.createSymbolicLink(at: runner, withDestinationURL: real)
        let backend = try #require(GameContainers.backends(f.paths).first)
        try await GameContainers.create(f.wine, backend: backend, paths: f.paths, requireIdle: {})
        #expect(f.wine.ready)
        let marker = f.wine.prefix.appendingPathComponent("drive_c/users/steamuser/container-validation.txt")
        try FileStore.write(Data("saved".utf8), to: marker)
        let copy = try await GameContainers.backup(f.wine, paths: f.paths, requireIdle: {})
        try FileStore.write(Data("changed".utf8), to: marker)
        try await GameContainers.restore(copy, to: f.wine, paths: f.paths, requireIdle: {})
        #expect(try FileStore.text(marker) == "saved")
        #expect(GameContainers.backups(f.wine, paths: f.paths).count == 2)
    }
}
