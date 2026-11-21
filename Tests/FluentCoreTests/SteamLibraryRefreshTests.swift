import Foundation
import Testing
@testable import FluentCore

struct SteamLibraryRefreshTests {
    private final class ProcessList: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32] = [123]
        func read() -> [Int32] { lock.withLock { values } }
        func replace(_ next: [Int32]) { lock.withLock { values = next } }
    }
    private func fixture() throws -> AppPaths {
        let paths = AppPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileStore.write(Data("Apps:\n  - 480\n".utf8), to: paths.config)
        return paths
    }
    @Test func stoppedSteamNeedsNoRestart() async throws {
        let p = try fixture(); defer { try? FileManager.default.removeItem(at: p.macSteam.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(await SteamLibraryRefresh.request(paths: p, pids: { [] }) == .nextLaunch)
        #expect(!FileManager.default.fileExists(atPath: p.config.path + ".refresh-request"))
    }
    @Test func oldReceiptDoesNotSucceed() async throws {
        let p = try fixture()
        try Data("old 123 old emitted\n".utf8).write(to: URL(fileURLWithPath: p.config.path + ".refresh-result"))
        #expect(await SteamLibraryRefresh.request(paths: p, timeout: 0.25, pids: { [123] }) == .restartRequired("refresh-timeout-or-old-extension"))
        #expect(!FileManager.default.fileExists(atPath: p.config.path + ".refresh-request"))
    }
    @Test func changedConfigRetriesOnce() async throws {
        let p = try fixture()
        let request = URL(fileURLWithPath: p.config.path + ".refresh-request")
        let receipt = URL(fileURLWithPath: p.config.path + ".refresh-result")
        let result = await SteamLibraryRefresh.request(paths: p, timeout: 0.5, pids: { [123] }, wake: {
            let text = try! String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let previous = (try? String(contentsOf: receipt, encoding: .utf8)) ?? ""
            let status = previous.isEmpty ? "config-changed" : "emitted"
            try! Data((text + " " + status).utf8).write(to: receipt, options: .atomic)
        })
        #expect(result == .notified)
    }
    @Test(arguments: ["emitted", "restart-required"])
    func correlatedReceipt(status: String) async throws {
        let p = try fixture()
        let responder = Task {
            let request = URL(fileURLWithPath: p.config.path + ".refresh-request")
            for _ in 0..<50 {
                if let text = try? String(contentsOf: request, encoding: .utf8) {
                    try Data((text.trimmingCharacters(in: .whitespacesAndNewlines) + " \(status)\n").utf8).write(to: URL(fileURLWithPath: p.config.path + ".refresh-result"), options: .atomic)
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let result = await SteamLibraryRefresh.request(paths: p, timeout: 2, pids: { [123] })
        try await responder.value
        #expect(result == (status == "emitted" ? .notified : .restartRequired(status)))
    }

    @Test(arguments: [true, false])
    func urlForwarderDoesNotReplaceOriginalSession(originalSurvives: Bool) async throws {
        let p = try fixture(), processes = ProcessList()
        let result = await SteamLibraryRefresh.request(paths: p, timeout: 0.5,
            pids: { processes.read() }, wake: {
                let request = URL(fileURLWithPath: p.config.path + ".refresh-request")
                let receipt = URL(fileURLWithPath: p.config.path + ".refresh-result")
                let text = try! String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                try! Data((text + " emitted\n").utf8).write(to: receipt, options: .atomic)
                processes.replace(originalSurvives ? [123, 456] : [456])
            })
        #expect(result == (originalSurvives ? .notified : .restartRequired("steam-session-changed")))
    }
}
