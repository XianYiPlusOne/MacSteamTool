import Foundation
import Testing
@testable import FluentCore
@testable import FluentSteam

@Suite @MainActor struct CloudDeleteFlowTests {
    @Test func previewBackupConfirmationAndDeleteUseRealService() async throws {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data")), sync = root.appendingPathComponent("Sync")
        var config = CloudConfiguration(); config.provider = .folder; config.folder = sync.path; try config.save(paths: paths)
        let source = sync.appendingPathComponent("12345/900001/进度.bin"), bytes = Data([0, 255, 42])
        try FileStore.write(bytes, to: source)
        let service = CloudGameDeletion(paths: paths, engine: URL(fileURLWithPath: "/not-used"), steamRunning: { false })
        let flow = CloudDeleteFlow(service: service, provider: .folder, account: "12345", app: 900001)
        flow.deleteConfirmed(); #expect(flow.operation == nil); #expect(try FileStore.read(source) == bytes)
        flow.load(); await flow.operation?.value
        #expect(flow.preview?.fileCount == 1); #expect(flow.backup == nil); #expect(!flow.complete)
        flow.createBackup(); await flow.operation?.value
        let backup = try #require(flow.backup); try service.verifyBackup(backup)
        // Closing/cancelling at this stage has no destructive effect.
        #expect(try FileStore.read(source) == bytes); #expect(!flow.complete)
        flow.deleteConfirmed(); await flow.operation?.value
        #expect(flow.complete); #expect(!FileStore.fm.fileExists(atPath: source.path))
        try service.verifyBackup(backup)
    }
    @Test func corruptBackupCannotMakeUIReportCompletion() async throws {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data")), sync = root.appendingPathComponent("Sync")
        var config = CloudConfiguration(); config.provider = .folder; config.folder = sync.path; try config.save(paths: paths)
        let source = sync.appendingPathComponent("12345/900001/save.bin"); try FileStore.write(Data([1]), to: source)
        let flow = CloudDeleteFlow(service: CloudGameDeletion(paths: paths, engine: URL(fileURLWithPath: "/not-used"), steamRunning: { false }), provider: .folder, account: "12345", app: 900001)
        flow.load(); await flow.operation?.value; flow.createBackup(); await flow.operation?.value
        let backup = try #require(flow.backup)
        try FileStore.write(Data([2]), to: backup.preview.directory.appendingPathComponent("local-0/data/save.bin"))
        flow.deleteConfirmed(); await flow.operation?.value
        #expect(!flow.complete); #expect(!flow.busy); #expect(flow.status.contains("corrupt") || flow.status.contains("损坏"))
        #expect(try FileStore.read(source) == Data([1]))
    }
}
