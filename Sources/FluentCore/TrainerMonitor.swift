import Foundation
import Darwin

@MainActor public final class TrainerMonitor {
    public let binding: TrainerBinding
    public let signature: String
    public let process: Process
    public let directory: URL
    public let logURL: URL
    private let lease: TrainerMonitorLease
    public init(binding: TrainerBinding, paths: AppPaths, signature: String, bundle: URL = Bundle.main.bundleURL) throws {
        try TrainerConfiguration.validate(binding)
        try FileStore.mkdir(paths.data.appendingPathComponent("TrainerSessions"))
        lease = try TrainerMonitorLease(url: paths.data.appendingPathComponent("TrainerSessions/\(binding.id.uuidString).lock"))
        self.binding = binding; self.signature = signature
        let helpers = bundle.appendingPathComponent("Contents/Resources/Helpers/Windows")
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
    public func heartbeat() {
        try? FileStore.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.appendingPathComponent("lease").path)
    }
    public var status: String {
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
    public func stop() {
        try? Data().write(to: directory.appendingPathComponent("stop"))
        let process = process, directory = directory, lease = lease
        Task {
            while process.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
            try? FileStore.fm.removeItem(at: directory)
            lease.release()
        }
    }
}

public struct TrainerMonitorBusy: Error {}
private final class TrainerMonitorLease {
    private var descriptor: Int32
    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppFailure("Cannot open trainer monitor lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; throw TrainerMonitorBusy() }
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { release() }
}
