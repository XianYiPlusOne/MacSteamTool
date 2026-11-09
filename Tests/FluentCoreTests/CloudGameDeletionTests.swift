import Foundation
import Testing
@testable import FluentCore

@Suite struct CloudGameDeletionTests {
    func fixture() throws -> (URL, AppPaths, CloudGameDeletion) {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CloudDelete-\(UUID().uuidString)")
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        var config = CloudConfiguration(); config.provider = .folder; config.folder = root.appendingPathComponent("Sync").path; try config.save(paths: paths)
        let service = CloudGameDeletion(paths: paths, engine: URL(fileURLWithPath: "/not-used"), steamRunning: { false })
        for directory in [root.appendingPathComponent("Sync/12345/900001"), paths.data.appendingPathComponent("CloudRedirect/storage/12345/900001"), paths.data.appendingPathComponent("CloudRedirect/blobs/12345/900001"), paths.steam.appendingPathComponent("userdata/12345/900001")] {
            try FileStore.write(Data([0, 1, 255]), to: directory.appendingPathComponent("子目录/进度.bin"))
            try FileStore.write(Data(), to: directory.appendingPathComponent("empty")); try FileStore.mkdir(directory.appendingPathComponent("empty-directory"))
        }
        for path in ["Sync/54321/900001/sentinel", "Sync/12345/900002/sentinel", "Data/CloudRedirect/storage/54321/900001/sentinel", "unrelated-game/save"] { try FileStore.write(Data("keep".utf8), to: root.appendingPathComponent(path)) }
        return (root, paths, service)
    }
    @Test func previewBackupDeleteAndScopeIsolation() async throws {
        let (root, _, service) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let preview = try await service.preview(provider: .folder, account: "12345", app: 900001)
        #expect(preview.local.count == 4); #expect(preview.fileCount == 8)
        #expect(!FileStore.fm.fileExists(atPath: preview.directory.path))
        let backup = try await service.backup(preview); try service.verifyBackup(backup)
        for target in preview.local { #expect(FileStore.fm.fileExists(atPath: target.path)) }
        try await service.delete(backup)
        for target in preview.local { #expect(!FileStore.fm.fileExists(atPath: target.path)) }
        try service.verifyBackup(backup)
        let status = try FileStore.decode([String: String].self, at: preview.directory.appendingPathComponent("deletion-status.json"))
        #expect(status["state"] == "complete")
        for path in ["Sync/54321/900001/sentinel", "Sync/12345/900002/sentinel", "Data/CloudRedirect/storage/54321/900001/sentinel", "unrelated-game/save"] { #expect(try FileStore.text(root.appendingPathComponent(path)) == "keep") }
    }
    @Test func changedSourceAndCorruptBackupRefuseBeforeDeletion() async throws {
        let (root, _, service) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let plan = try await service.preview(provider: .folder, account: "12345", app: 900001)
        let first = URL(fileURLWithPath: plan.local[0].path).appendingPathComponent("empty")
        try FileStore.write(Data([1]), to: first)
        await #expect(throws: (any Error).self) { try await service.backup(plan) }
        #expect(!FileStore.fm.fileExists(atPath: plan.directory.path))
        try FileStore.write(Data(), to: first)
        let fresh = try await service.preview(provider: .folder, account: "12345", app: 900001), backup = try await service.backup(fresh)
        try FileStore.write(Data([7]), to: fresh.directory.appendingPathComponent("local-0/data/empty"))
        await #expect(throws: (any Error).self) { try await service.delete(backup) }
        for target in fresh.local { #expect(FileStore.fm.fileExists(atPath: target.path)) }
        #expect(!FileStore.fm.fileExists(atPath: fresh.directory.appendingPathComponent("deletion-status.json").path))
    }
    @Test func addedTargetAfterBackupOrConfigurationChangeIsRejected() async throws {
        let (root, paths, service) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let plan = try await service.preview(provider: .folder, account: "12345", app: 900001), backup = try await service.backup(plan)
        try FileStore.write(Data([1]), to: URL(fileURLWithPath: plan.local[0].path).appendingPathComponent("new-save"))
        await #expect(throws: (any Error).self) { try await service.delete(backup) }
        try FileStore.fm.removeItem(at: URL(fileURLWithPath: plan.local[0].path).appendingPathComponent("new-save"))
        var config = try CloudConfiguration.load(paths: paths); config.enabled = false; config.apps = "42"; try config.save(paths: paths)
        await #expect(throws: (any Error).self) { try await service.delete(backup) }
        for target in plan.local { #expect(FileStore.fm.fileExists(atPath: target.path)) }
    }
    @Test func symlinkAndRunningSteamAreRejected() async throws {
        let (root, paths, service) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("Sync/12345/900001")
        try FileStore.fm.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: root.appendingPathComponent("unrelated-game"))
        await #expect(throws: (any Error).self) { try await service.preview(provider: .folder, account: "12345", app: 900001) }
        let blocked = CloudGameDeletion(paths: paths, engine: URL(fileURLWithPath: "/not-used"), steamRunning: { true })
        await #expect(throws: (any Error).self) { try await blocked.preview(provider: .folder, account: "12345", app: 900001) }
        #expect(try FileStore.text(root.appendingPathComponent("unrelated-game/save")) == "keep")
    }
    @Test func incompleteOrEscapingRemoteListingFailsClosed() async throws {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        var config = CloudConfiguration(); config.provider = .webdav; try config.save(paths: paths)
        for response in [#"{"success":true,"complete":false,"files":[]}"#, #"{"success":true,"complete":true,"files":[{"path":"12345/900001/../other","size":0,"modified_time":0}]}"#, #"{"success":true,"complete":true,"files":[{"path":"54321/900001/file","size":0,"modified_time":0}]}"#] {
            let service = CloudGameDeletion(paths: paths, engine: URL(fileURLWithPath: "/not-used"), steamRunning: { false }, execute: { arguments in #expect(arguments.first == "list-remote-app-files"); return response })
            await #expect(throws: (any Error).self) { try await service.preview(provider: .webdav, account: "12345", app: 900001) }
        }
        #expect(!FileStore.fm.fileExists(atPath: CloudGameDeletion.backupRoot(paths).path))
    }
}
