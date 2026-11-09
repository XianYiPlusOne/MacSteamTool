import Foundation
import FluentCore
import Darwin

@main struct Agent {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let settings = URL(fileURLWithPath: CommandLine.arguments[1])
        let defaults = AppPaths(data: settings.deletingLastPathComponent())
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var stopped = false
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        term.setEventHandler { stopped = true }; interrupt.setEventHandler { stopped = true }
        term.resume(); interrupt.resume()
        var monitors: [UUID: TrainerMonitor] = [:], retired: [TrainerMonitor] = []
        var failure: [UUID: (TrainerBinding, Date)] = [:]
        // A former parent may have crashed; let its Windows helper's 20s lease expire.
        for _ in 0..<22 where !stopped { try? await Task.sleep(for: .seconds(1)) }
        while !stopped {
            do {
                let preferences = try FileStore.decode(Preferences.self, at: settings)
                guard preferences.independentTrainerMonitor == true else { break }
                let paths = preferences.applying(to: defaults)
                let signature = [paths.steam.path, paths.notProton.path, paths.data.path].joined(separator: "\n")
                let enabled = preferences.trainers.filter(\.autoLaunch)
                for (id, monitor) in monitors where !enabled.contains(where: { $0 == monitor.binding && monitor.signature == signature }) {
                    monitor.stop(); retired.append(monitor); monitors.removeValue(forKey: id)
                }
                retired.removeAll { !$0.process.isRunning }
                var states: [String: String] = [:]
                for binding in enabled {
                    if let monitor = monitors[binding.id], !monitor.process.isRunning { monitor.stop(); retired.append(monitor); monitors.removeValue(forKey: binding.id); failure[binding.id] = (binding, Date()) }
                    if monitors[binding.id] == nil {
                        if let (previous, date) = failure[binding.id], previous == binding, Date().timeIntervalSince(date) < 30 { states[binding.id.uuidString] = "启动失败，30 秒后重试 / Launch failed; retrying in 30 seconds"; continue }
                        do { monitors[binding.id] = try TrainerMonitor(binding: binding, paths: paths, signature: signature, bundle: bundle); failure.removeValue(forKey: binding.id) }
                        catch { states[binding.id.uuidString] = error.localizedDescription; failure[binding.id] = (binding, Date()); continue }
                    }
                    if let monitor = monitors[binding.id] { monitor.heartbeat(); states[binding.id.uuidString] = monitor.status }
                }
                try FileStore.json(TrainerAgentStatus(bindings: states), to: paths.data.appendingPathComponent("TrainerAgent/status.json"))
            } catch {
                // Invalid configuration stops active monitors; never continue using stale paths.
                for monitor in monitors.values { monitor.stop(); retired.append(monitor) }; monitors.removeAll()
            }
            try? await Task.sleep(for: .seconds(2))
        }
        for monitor in monitors.values { monitor.stop(); retired.append(monitor) }
        for _ in 0..<40 where retired.contains(where: { $0.process.isRunning }) { try? await Task.sleep(for: .milliseconds(250)) }
    }
}
