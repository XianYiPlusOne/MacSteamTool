import Foundation
import Testing
@testable import MacSteamToolCore
@testable import MacSteamTool

/// Exercises the real pipe reader/process lifecycle without Steam or a network.
@Suite @MainActor struct MultiplayerFlowTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw AppFailure("Multiplayer service did not reach the expected state")
    }
    @Test func serviceErrorsPreserveDraftAndRestartDoesNotReuseOldConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluentConnectTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("service")
        let script = #"""
        #!/usr/bin/env python3
        import json, os, sys
        from pathlib import Path
        root = Path(__file__).parent
        with (root/'starts').open('a') as f: f.write('start\n')
        def emit(value):
            data = (json.dumps(value) + '\n').encode()
            os.write(1, data[:7]); os.write(1, data[7:])
        emit({'type':'state','state':{'steamReady':True,'lobbyId':'','messages':[]}})
        for line in sys.stdin:
            c = json.loads(line)
            if c['operation'] == 'crash': os._exit(7)
            if c['operation'] == 'quit': break
            if c['operation'] == 'chat' and c['text'] == 'reject':
                emit({'type':'error','id':c['id'],'message':'test rejection'})
            else: emit({'type':'ack','id':c['id']})
        (root/'stopped').write_text('stopped')
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = MultiplayerController(executable: executable)
        defer { client.stop(); try? FileManager.default.removeItem(at: root) }
        #expect(!client.running && !client.starting && !FileManager.default.fileExists(atPath: root.appendingPathComponent("starts").path))
        client.start(); client.start()
        try await until { client.running }
        #expect(try String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8) == "start\n")
        client.draft = "reject"; client.sendChat()
        try await until { client.failure == "test rejection" }
        #expect(client.draft == "reject")
        client.draft = "accepted"; client.sendChat()
        try await until { client.draft.isEmpty }
        client.send("crash")
        try await until { !client.running }
        #expect(client.state.steamReady == nil)
        #expect(client.failure?.contains("7") == true)
        client.start()
        try await until { client.running }
        #expect(client.failure == nil)
        client.stop()
        #expect(!client.running && !client.state.active)
        client.start() // A second helper must not overlap the one still shutting down.
        try await until { !client.stopping }
        #expect(try String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8) == "start\nstart\n")
        #expect(client.failure == nil)
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("stopped").path) }
    }
}
