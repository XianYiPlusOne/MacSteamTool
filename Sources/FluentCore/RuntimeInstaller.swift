import Foundation

/// The installer also checks Steam's bootstrap process, which can appear before
/// proc_pidpath exposes a usable client path to the UI process.
public struct SteamPreparationRequiresExit: LocalizedError {
    public init() {}
    public var errorDescription: String? { "请退出 Steam 后自动继续 / Quit Steam to continue automatically" }
}

public struct RuntimeBackup: Identifiable, Sendable {
    public let folder: URL
    public let date: Date
    public let interrupted: Bool
    public var id: String { folder.lastPathComponent }
    public var isNotProton: Bool { id.hasPrefix("NotProton-") }
}
public enum RuntimeInstaller {
    private struct Request: Encodable {
        var companion: String
        var steamApp: String
        var steamData: String
        var notProton: String
        var data: String
        var crossOver: String?
        var backup: String?
        var kernel: String?
        var source: String?
        var macSteam: String
        var remove: Bool?
        var cleanRunners: Bool?
        var recoverInterrupted: Bool?
        var managedRoot: String?
        var managedVersion: String?
        var rebuildExecutable: String?
    }
    private struct Response: Decodable { var ok: Bool; var error: String?; var backup: String? }
    public static func backups(_ paths: AppPaths) -> [RuntimeBackup] {
        FileStore.files(paths.data.appendingPathComponent("RuntimeBackups")).compactMap { folder in
            let status = (try? FileStore.text(folder.appendingPathComponent("status"))) ?? ""
            let interrupted = status == "incomplete\n" || status == "recovery-needed\n"
            guard folder.lastPathComponent.hasPrefix("NotProton-") || folder.lastPathComponent.hasPrefix("Kernel-"),
                  FileStore.fm.fileExists(atPath: folder.appendingPathComponent("snapshot.json").path),
                  interrupted || FileStore.fm.fileExists(atPath: folder.appendingPathComponent("installed.json").path), status != "restored\n" else { return nil }
            return RuntimeBackup(folder: folder, date: (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, interrupted: interrupted)
        }.sorted { $0.date > $1.date }
    }
    public static func run(paths: AppPaths, kernel: String? = nil, source: URL? = nil, companion: URL? = nil, crossOver: URL? = nil, remove: Bool = false, cleanRunners: Bool = false, restoring: RuntimeBackup? = nil, managedRoot: URL? = nil, managedVersion: String? = nil, application: URL = Bundle.main.bundleURL, status: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        guard #available(macOS 15, *) else { throw AppFailure("macSteam / NotProton 内核安装需要 macOS 15 或更新版本") }
        let executable = application.appendingPathComponent("Contents/Helpers/NotProton/FluentNotProton")
        guard FileStore.fm.isExecutableFile(atPath: executable.path) else { throw AppFailure("未找到内核安装器，请重新完整打包应用 / Kernel installer missing; rebuild the complete application") }
        let repair = kernel == "notproton.dylib" && !remove ? application.appendingPathComponent("Contents/Resources/Helpers/NotProtonRepair/notproton.dylib") : nil
        let r = Request(companion: companion?.path ?? "", steamApp: paths.steamApp.path, steamData: paths.steam.path, notProton: paths.notProton.path, data: paths.data.path, crossOver: crossOver?.path, backup: restoring?.folder.path, kernel: kernel, source: (source ?? repair)?.path, macSteam: paths.macSteam.path, remove: remove, cleanRunners: cleanRunners, recoverInterrupted: restoring?.interrupted, managedRoot: managedRoot?.path, managedVersion: managedVersion, rebuildExecutable: managedRoot == nil ? nil : executable.path)
        let command = restoring.map { $0.isNotProton ? "--restore" : "--restore-kernel" } ?? (kernel == nil ? "--install" : "--kernel")
        // Installation cannot be killed halfway through signing or swapping Steam.app.
        // The helper owns rollback and continues to completion even if this UI task is cancelled.
        return try await Task.detached {
            let folder = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentRuntime-\(UUID().uuidString)")
            try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileStore.fm.removeItem(at: folder) }
            let input = folder.appendingPathComponent("request.json"), output = folder.appendingPathComponent("response.json")
            try FileStore.json(r, to: input)
            let process = Process(); process.executableURL = executable; process.arguments = [command, input.path, output.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            var last = ""
            while process.isRunning {
                if let data = try? FileStore.read(URL(fileURLWithPath: output.path + ".status")), let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["progress"], message != last {
                    last = message; await status(message)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            // The child has exited; avoid a RunLoop wait after async polling.
            guard FileStore.fm.fileExists(atPath: output.path) else { throw AppFailure("内核安装器异常退出 / Kernel installer exited unexpectedly（\(process.terminationStatus)）；请检查 RuntimeBackups 中的备份 / Check the backup in RuntimeBackups") }
            let response = try FileStore.decode(Response.self, at: output)
            if !response.ok, response.error?.hasPrefix("Close Steam:") == true { throw SteamPreparationRequiresExit() }
            guard response.ok, let backup = response.backup else { throw AppFailure(response.error ?? "内核操作失败 / Kernel operation failed") }
            return URL(fileURLWithPath: backup)
        }.value
    }
}
