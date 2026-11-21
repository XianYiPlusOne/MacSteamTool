import Foundation
import Testing
import Darwin
@testable import FluentCore

@Suite struct ContainerProfileTests {
    typealias Fixture = GameContainerTests.Fixture

    @Test func namedProfilesRoundTripThroughThePathUsedBySteam() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runner = try f.freeRunner()
        try f.seed(f.wine, value: "legacy"); try f.seed(f.crossOver, value: "existing CrossOver")
        let profiles = ContainerProfiles(appID: 42, library: f.paths.steam, paths: f.paths)
        let config = f.paths.steam.appendingPathComponent("config/config.vdf")
        let originalConfig = try FileStore.read(config)
        let mod = try await profiles.create(name: "MOD", backend: runner)
        let clean = try await profiles.create(name: "Vanilla", backend: runner)
        #expect(try profiles.list().count == 3)
        #expect(try FileStore.read(config) == originalConfig)
        let save = f.wine.prefix.appendingPathComponent("drive_c/users/steamuser/save.dat")
        #expect(try FileStore.text(save) == "legacy")
        try await profiles.activate(mod, requireIdle: {})
        #expect(try profiles.list().first?.id == mod)
        #expect(try SteamLibrary.prefixes(f.paths).first?.url.standardizedFileURL == f.wine.prefix.standardizedFileURL)
        #expect(!FileStore.fm.fileExists(atPath: save.path))
        try FileStore.write(Data("mod save".utf8), to: save)
        try await profiles.activate(clean, requireIdle: {})
        #expect(!FileStore.fm.fileExists(atPath: save.path))
        try FileStore.write(Data("clean save".utf8), to: save)
        try await profiles.activate(mod, requireIdle: {})
        #expect(try FileStore.text(save) == "mod save")
        let original = try #require(profiles.list().first(where: { $0.name == nil })?.id)
        try await profiles.activate(original, requireIdle: {})
        #expect(try FileStore.text(save) == "legacy")
        #expect(try FileStore.text(f.crossOver.prefix.appendingPathComponent("user.reg")) == "existing CrossOver")
        #expect(try FileStore.read(config) == originalConfig)
    }

    @Test func duplicateNamesAndBusyPrefixesLeaveSelectionIntact() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runner = try f.freeRunner(); try f.seed(f.wine)
        let profiles = ContainerProfiles(appID: 42, library: f.paths.steam, paths: f.paths)
        let id = try await profiles.create(name: " A ", backend: runner)
        await #expect(throws: (any Error).self) { try await profiles.create(name: "a", backend: runner) }
        await #expect(throws: (any Error).self) { try await profiles.create(name: " ", backend: runner) }
        await #expect(throws: (any Error).self) { try await profiles.activate(id, requireIdle: { throw AppFailure("busy") }) }
        let lock = open(f.wine.root.appendingPathComponent(".notproton-prefix.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: (any Error).self) { try await profiles.activate(id, requireIdle: {}) }
        #expect(try profiles.list().count == 2)
        #expect(try profiles.list().first?.name == nil)
        #expect(try FileStore.text(f.wine.prefix.appendingPathComponent("user.reg")) == "old save")
    }

    @Test func failedMappingRollsBackTheDirectorySwap() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runner = try f.freeRunner(); try f.seed(f.wine)
        let config = f.paths.steam.appendingPathComponent("config/config.vdf")
        try FileStore.write(SteamCompatibility.edit(FileStore.read(config), appID: 42, tool: "other-tool"), to: config)
        let profiles = ContainerProfiles(appID: 42, library: f.paths.steam, paths: f.paths)
        let id = try await profiles.create(name: "Fresh", backend: runner)
        try FileStore.write(Data(), to: f.paths.data.appendingPathComponent("CompatibilityBackups"))
        await #expect(throws: (any Error).self) { try await profiles.activate(id, requireIdle: {}) }
        #expect(try profiles.list().first?.name == nil)
        #expect(try GameContainers.selectedTool(appID: 42, paths: f.paths) == "other-tool")
        #expect(try FileStore.text(f.wine.prefix.appendingPathComponent("user.reg")) == "old save")
    }
    @Test func backupsRemainAssociatedWithTheirOwnProfile() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runner = try f.freeRunner(); try f.seed(f.wine)
        let profiles = ContainerProfiles(appID: 42, library: f.paths.steam, paths: f.paths)
        let oldCopy = try await GameContainers.backup(f.wine, paths: f.paths, requireIdle: {})
        let id = try await profiles.create(name: "MOD", backend: runner)
        try await profiles.activate(id, requireIdle: {})
        #expect(GameContainers.backups(f.wine, paths: f.paths).isEmpty)
        await #expect(throws: (any Error).self) { try await GameContainers.restore(oldCopy, to: f.wine, paths: f.paths, requireIdle: {}) }
        let namedCopy = try await GameContainers.backup(f.wine, paths: f.paths, requireIdle: {})
        let original = try #require(profiles.list().first(where: { $0.name == nil })?.id)
        try await profiles.activate(original, requireIdle: {})
        #expect(GameContainers.backups(f.wine, paths: f.paths).map(\.id) == [oldCopy.id])
        await #expect(throws: (any Error).self) { try await GameContainers.restore(namedCopy, to: f.wine, paths: f.paths, requireIdle: {}) }
    }

    @Test func interruptedSwapRecoversBeforeAnotherActivation() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runner = try f.freeRunner(); try f.seed(f.wine)
        let profiles = ContainerProfiles(appID: 42, library: f.paths.steam, paths: f.paths)
        let id = try await profiles.create(name: "MOD", backend: runner)
        let parked = try #require(profiles.list().first(where: { $0.id == id }))
        let priorID = UUID(), root = f.crossOver.root, dir = parked.directory
        try FileStore.json(ContainerProfiles.Record(id: priorID, name: nil, tool: nil), to: root.appendingPathComponent(ContainerProfiles.marker))
        try FileStore.json(["previous": priorID.uuidString, "next": id.uuidString, "slot": dir.lastPathComponent, "nextTool": runner.id],
                           to: dir.deletingLastPathComponent().appendingPathComponent(".switch.json"))
        #expect(renamex_np(root.path, dir.path, UInt32(RENAME_SWAP)) == 0)
        try await profiles.recover(requireIdle: {})
        #expect(!profiles.needsRecovery)
        #expect(try profiles.list().first?.id == priorID)
        #expect(try FileStore.text(f.wine.prefix.appendingPathComponent("system.reg")) == "old save")
        try await profiles.activate(id, requireIdle: {})
        #expect(try profiles.list().first?.id == id)
    }
}
