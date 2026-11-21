import Foundation
import CryptoKit

public enum SteamLibraryRefresh {
    public enum Result: Equatable, Sendable {
        case nextLaunch
        case notified
        case restartRequired(String)
    }

    /// A matching native receipt confirms emission of the library update event,
    /// not that the web UI has rendered it or that a download can succeed.
    public static func request(paths: AppPaths, timeout: TimeInterval = 8,
                               pids: @Sendable () -> [Int32] = { SteamProcesses.pids() },
                               wake: @Sendable () async -> Void = {}) async -> Result {
        let first = await requestOnce(paths: paths, timeout: timeout, pids: pids, wake: wake)
        if first == .restartRequired("config-changed") {
            return await requestOnce(paths: paths, timeout: timeout, pids: pids, wake: wake)
        }
        return first
    }

    private static func requestOnce(paths: AppPaths, timeout: TimeInterval,
                                    pids: @Sendable () -> [Int32],
                                    wake: @Sendable () async -> Void) async -> Result {
        let running = Array(Set(pids())).sorted()
        guard !running.isEmpty else { return .nextLaunch }
        guard running.count == 1 else { return .restartRequired("multiple-steam-processes") }
        let pid = running[0], token = UUID().uuidString
        let request = URL(fileURLWithPath: paths.config.path + ".refresh-request")
        let receipt = URL(fileURLWithPath: paths.config.path + ".refresh-result")
        do {
            let hash = SHA256.hash(data: try Data(contentsOf: paths.config)).map { String(format: "%02x", $0) }.joined()
            let text = "\(token) \(pid) \(hash)\n"
            try Data(text.utf8).write(to: request, options: .atomic)
            defer {
                // Do not remove a newer request from another app instance.
                if (try? String(contentsOf: request, encoding: .utf8)) == text { try? FileManager.default.removeItem(at: request) }
            }
            await wake()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                // Opening a steam:// URL may briefly spawn another steam_osx
                // process to forward the URL. Track our original session only.
                guard pids().contains(pid) else { return .restartRequired("steam-session-changed") }
                if let value = try? String(contentsOf: receipt, encoding: .utf8) {
                    let fields = value.split(whereSeparator: \.isWhitespace).map(String.init)
                    if fields.count == 4, fields[0] == token, fields[1] == String(pid), fields[2] == hash {
                        let current = SHA256.hash(data: try Data(contentsOf: paths.config)).map { String(format: "%02x", $0) }.joined()
                        guard current == hash else { return .restartRequired("config-changed") }
                        guard fields[3] == "emitted" else { return .restartRequired(fields[3]) }
                        // A native callback receipt alone must not hide an immediately
                        // failing Steam session (e.g. an unsupported client build).
                        for _ in 0..<10 {
                            try await Task.sleep(for: .milliseconds(200))
                            guard pids().contains(pid) else { return .restartRequired("steam-session-changed") }
                        }
                        return .notified
                    }
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            return .restartRequired("refresh-timeout-or-old-extension")
        } catch { return .restartRequired("refresh-unavailable") }
    }
}
