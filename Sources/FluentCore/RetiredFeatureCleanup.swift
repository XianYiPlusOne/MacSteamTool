import Foundation
import Darwin

/// Upgrade-only removal of the retired trainer feature. This cannot register or launch helpers.
public enum RetiredFeatureCleanup {
    private static let label = "dev.fluentsteam.mac.trainer-agent"

    public static func run(home: URL, paths: AppPaths, launchctl: ([String]) throws -> Int32 = runLaunchctl) throws {
        // Stop owned Windows monitors before unloading their former parent. Do not terminate
        // Wine, games, or processes found by name, and never delete downloaded executables.
        let sessions = paths.data.appendingPathComponent("TrainerSessions")
        if let info = try? sessions.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), info.isDirectory == true, info.isSymbolicLink != true {
            for directory in try FileStore.fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
                let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
                let config = directory.appendingPathComponent("config.json"), stop = directory.appendingPathComponent("stop")
                guard (try? config.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let data = try? FileStore.read(config),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recordedStop = record["stop"] as? String, matchesStop(recordedStop, stop),
                      (try? stop.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                try FileStore.write(Data(), to: stop)
            }
        }
        // Remove only the obsolete fields, preserving every unrelated setting, including
        // keys introduced by newer versions. Invalid JSON is retained for manual recovery.
        var settingsError: Error?
        do {
            if FileStore.fm.fileExists(atPath: paths.settings.path) {
                guard var record = try JSONSerialization.jsonObject(with: FileStore.read(paths.settings)) as? [String: Any] else { throw AppFailure("设置必须是 JSON 对象 / Settings must be a JSON object") }
                let changed = record.removeValue(forKey: "trainers") != nil
                let monitor = record.removeValue(forKey: "independentTrainerMonitor") != nil
                if changed || monitor { try FileStore.write(JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), to: paths.settings) }
            }
        } catch { settingsError = error }
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let exists = FileStore.fm.fileExists(atPath: plist.path)
        if exists {
            guard (try plist.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  let record = try PropertyListSerialization.propertyList(from: FileStore.read(plist), format: nil) as? [String: Any], record["Label"] as? String == label else {
                throw AppFailure("旧后台项身份不符，已保留 / Obsolete background item identity mismatch; retained")
            }
        }
        let target = "gui/\(getuid())/\(label)"
        // Query the exact service even if its plist was removed while it was running.
        if try launchctl(["print", target]) == 0 || exists {
            let status = try launchctl(["bootout", target])
            guard [0, 3, 113].contains(status) else { throw AppFailure("停止旧后台项失败 / Failed to stop obsolete background item: \(status)") }
            if exists { try FileStore.fm.removeItem(at: plist) }
        }
        if let settingsError { throw settingsError }
    }

    private static func matchesStop(_ recorded: String, _ expected: URL) -> Bool {
        guard recorded.hasPrefix("Z:\\") else { return false }
        let file = URL(fileURLWithPath: String(recorded.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
        guard file.lastPathComponent == "stop" else { return false }
        // Foundation may report /var and /private/var differently before/after creating
        // the stop file. Compare the actual parent directories, not those aliases.
        func parent(_ url: URL) -> String? {
            guard let path = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
            defer { free(path) }; return String(cString: path)
        }
        guard let actual = parent(file), let target = parent(expected) else { return false }
        return actual == target
    }

    public static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
}
