import Foundation
import Testing
@testable import MacSteamToolCore
@testable import MacSteamTool

@Suite @MainActor struct TunHelperFlowTests {
    @Test func cancellationAndFailedProbeNeverReportReadyAndRepairCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluentTunFlow-\(UUID().uuidString)")
        try FileStore.mkdir(root); defer { try? FileManager.default.removeItem(at: root) }
        let setup = TunHelperController(resources: root)
        try FileStore.write(Data("fixture".utf8), to: setup.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: setup.helper.path)
        try FileStore.write(Data("fixture plist".utf8), to: setup.plist)
        var authorized = false, working = false, probes = 0
        setup.run = { executable, _ in
            if executable.lastPathComponent == "codesign" { return (0, "") }
            if executable.lastPathComponent == "osascript" { return authorized ? (0, "installed") : (1, "User canceled. (-128)") }
            probes += 1
            return working ? (0, "OK utun9\n") : (1, "Permission denied")
        }
        await setup.repair()
        #expect(!setup.ready && !setup.busy && setup.checked && probes == 0)
        #expect(setup.message.contains("取消"))
        authorized = true; await setup.repair()
        #expect(!setup.ready && !setup.busy && probes == 1)
        #expect(setup.detail.contains("Permission denied"))
        working = true; await setup.repair()
        #expect(setup.ready && !setup.busy && probes == 2 && setup.detail.isEmpty)
        working = false; await setup.check()
        #expect(!setup.ready && !setup.busy && probes == 3)
    }
}
