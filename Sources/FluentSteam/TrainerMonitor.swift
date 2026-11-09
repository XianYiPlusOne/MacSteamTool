import AppKit
import FluentCore

extension AppModel {
    func reconcileTrainerMonitors() {
        guard !testing else { return }
        if preferences.independentTrainerMonitor == true {
            stopTrainerMonitors()
            if let status = try? FileStore.decode(TrainerAgentStatus.self, at: paths.data.appendingPathComponent("TrainerAgent/status.json")), Date().timeIntervalSince(status.date) < 15 {
                trainerStatus = Dictionary(uniqueKeysWithValues: status.bindings.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
            } else {
                trainerStatus = Dictionary(uniqueKeysWithValues: preferences.trainers.filter(\.autoLaunch).map { ($0.id, "等待后台助手状态（启动约 22 秒） / Waiting for background agent (about 22 seconds)") })
            }
            return
        }
        let location = [paths.steam.path, paths.notProton.path, paths.data.path].joined(separator: "\n")
        let enabled = preferences.trainers.filter(\.autoLaunch)
        for (id, monitor) in trainerMonitors where !enabled.contains(where: { $0.id == id && $0 == monitor.binding && monitor.signature == location }) {
            monitor.stop(); retiringTrainers[id] = monitor; trainerMonitors.removeValue(forKey: id); trainerStatus.removeValue(forKey: id)
        }
        for (id, monitor) in retiringTrainers where !monitor.process.isRunning { retiringTrainers.removeValue(forKey: id) }
        for binding in enabled {
            if retiringTrainers[binding.id] != nil { trainerStatus[binding.id] = "正在结束上一监控会话"; continue }
            if let monitor = trainerMonitors[binding.id] { monitor.heartbeat(); trainerStatus[binding.id] = monitor.status; continue }
            guard trainerFailures[binding.id] != binding else { continue }
            do {
                let monitor = try TrainerMonitor(binding: binding, paths: paths, signature: location)
                trainerMonitors[binding.id] = monitor; trainerStatus[binding.id] = monitor.status
            } catch is TrainerMonitorBusy { trainerStatus[binding.id] = "等待其他监控会话退出 / Waiting for the other monitor session" }
            catch { trainerFailures[binding.id] = binding; trainerStatus[binding.id] = error.localizedDescription; log(error.localizedDescription) }
        }
        for id in trainerFailures.keys where !enabled.contains(where: { $0.id == id }) { trainerFailures.removeValue(forKey: id) }
        runningTools.removeAll { !$0.isRunning }
    }
    func stopTrainerMonitors() { for monitor in Array(trainerMonitors.values) + Array(retiringTrainers.values) { monitor.stop() }; trainerMonitors.removeAll(); retiringTrainers.removeAll() }
    func configureTrainer(_ binding: TrainerBinding, game: String, keys: String, delay: Int, enabled: Bool) throws {
        guard let index = preferences.trainers.firstIndex(where: { $0.id == binding.id }) else { return }
        var updated = binding; updated.gameExecutable = game; updated.autoKeys = try TrainerConfiguration.shortcuts(keys); updated.keyDelay = delay; updated.autoLaunch = enabled
        if enabled { try TrainerConfiguration.validate(updated) }
        preferences.trainers[index] = updated; trainerFailures.removeValue(forKey: binding.id)
        if let prior = trainerMonitors[binding.id], !prior.process.isRunning { prior.stop(); trainerMonitors.removeValue(forKey: binding.id) }
        savePreferences()
    }
}
