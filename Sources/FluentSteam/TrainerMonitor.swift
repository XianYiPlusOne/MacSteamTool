import AppKit
import FluentCore

@MainActor final class TrainerMonitor {
    let binding: TrainerBinding
    let signature: String
    let process: Process
    let directory: URL
    let logURL: URL
    init(binding: TrainerBinding, paths: AppPaths, signature: String) throws {
        try TrainerConfiguration.validate(binding)
        self.binding = binding; self.signature = signature
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/Windows")
        let python = helpers.appendingPathComponent("python.exe"), script = helpers.appendingPathComponent("trainer_monitor.py")
        guard FileStore.fm.fileExists(atPath: python.path), FileStore.fm.fileExists(atPath: script.path) else { throw AppFailure("应用缺少修改器监控助手，请重新构建或安装完整版 / Trainer monitor missing; rebuild or install the complete application") }
        directory = paths.data.appendingPathComponent("TrainerSessions/\(UUID().uuidString)")
        logURL = paths.data.appendingPathComponent("Logs/trainer-monitor-\(binding.id.uuidString).log")
        try FileStore.fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let config: [String: Any] = ["game": try TrainerConfiguration.windowsPath(binding.gameExecutable!), "trainer": try TrainerConfiguration.windowsPath(binding.executable), "keys": binding.autoKeys ?? [], "delay": binding.keyDelay ?? 5, "stop": try TrainerConfiguration.windowsPath(directory.appendingPathComponent("stop").path), "lease": try TrainerConfiguration.windowsPath(directory.appendingPathComponent("lease").path)]
            let file = directory.appendingPathComponent("config.json")
            try JSONSerialization.data(withJSONObject: config).write(to: file, options: .atomic)
            try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Data().write(to: directory.appendingPathComponent("lease"))
            var launch = try WineLaunch.prepare(appID: binding.appID, command: python.path, paths: paths)
            launch.arguments += [try TrainerConfiguration.windowsPath(script.path), try TrainerConfiguration.windowsPath(file.path)]
            process = try launch.launch(log: logURL)
        } catch { try? FileStore.fm.removeItem(at: directory); throw error }
    }
    func heartbeat() {
        try? FileStore.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.appendingPathComponent("lease").path)
    }
    var status: String {
        guard process.isRunning else { return "监控已退出（\(process.terminationStatus)），检查日志后重新启用" }
        guard let text = try? FileStore.text(logURL), let line = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix("{\"state\":") }), let data = line.data(using: .utf8), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "正在启动监控" }
        switch item["state"] as? String {
        case "watching": return "等待游戏进程"
        case "trainer-started": return "修改器已自动启动"
        case "shortcuts-sent": return "已发送 \(item["count"] ?? 0) 个快捷键，跳过 \(item["skipped"] ?? 0) 个"
        case "trainer-stopped": return "游戏退出，已结束本次启动的修改器"
        case "existing-trainer-kept": return "检测到已运行的修改器"
        case "error": return item["message"] as? String ?? "监控出错"
        default: return "正在监控"
        }
    }
    func stop() {
        try? Data().write(to: directory.appendingPathComponent("stop"))
        let process = process, directory = directory
        Task {
            for _ in 0..<40 where process.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
            if !process.isRunning { try? FileStore.fm.removeItem(at: directory) }
        }
    }
}

extension AppModel {
    func reconcileTrainerMonitors() {
        guard !testing else { return }
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
            } catch { trainerFailures[binding.id] = binding; trainerStatus[binding.id] = error.localizedDescription; log(error.localizedDescription) }
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
