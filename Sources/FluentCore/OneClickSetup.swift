import Foundation
import Darwin

public struct SetupOptions: Sendable {
    public var macSteamSource: URL?
    public var notProtonSource: URL?
    public init() {}
}

public struct SetupJournal: Codable, Sendable {
    public var started = Date()
    public var state = "preparing"
    public var step = ""
    public var completed: [String] = []
    public var backups: [String] = []
    public var error: String?
    public var awaitingFirstSteamLaunch = false
}

/// Each deployment owns its own verified backup/rollback. The journal describes
/// partial success honestly; a retry revalidates the installed state.
public enum OneClickSetup {
    public struct Prepared: Sendable {
        public var paths: AppPaths
        public var options: SetupOptions
        public var steam: URL?
        public var macSteam: ManagedRuntimeComponent?
        public var notProton: ManagedRuntimeComponent?
        public var awaitingFirstSteamLaunch: Bool
    }
    public static func journalURL(_ paths: AppPaths) -> URL { paths.data.appendingPathComponent("Setup/latest.json") }
    public static func requiresRosetta(_ prepared: Prepared) -> Bool { prepared.steam != nil }
    public static func preserveNewer(installed: String, candidate: String) -> Bool {
        installed.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil && installed.compare(candidate, options: .numeric) == .orderedDescending
    }
    public static func rosettaAvailable() async -> Bool {
        (try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"]).0) == 0
    }
    /// Called only after the user accepts Apple's terms in the setup UI. The
    /// system owns authentication; no password passes through this application.
    public static func installRosetta(consent: Bool) async throws {
        guard consent else { throw AppFailure("请先阅读并同意 Apple 的 Rosetta 许可 / Accept Apple's Rosetta license first") }
        if await rosettaAvailable() { return }
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        let (code, detail) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
        guard code == 0, await rosettaAvailable() else { throw AppFailure("Rosetta 未安装 / Rosetta installation did not finish: \(detail.suffix(1000))") }
    }
    public static func resolveSteamPath(_ paths: AppPaths) -> AppPaths {
        var p = paths
        let userApp = FileStore.fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Steam.app")
        if p.steamApp.path == "/Applications/Steam.app", !FileStore.fm.fileExists(atPath: p.steamApp.path) {
            if FileStore.fm.fileExists(atPath: userApp.path) || !FileStore.fm.isWritableFile(atPath: "/Applications") { p.steamApp = userApp }
        }
        return p
    }
    public static func prepare(paths: AppPaths, options: SetupOptions, application: URL,
                               progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> Prepared {
        guard #available(macOS 15, *) else { throw AppFailure("自动准备需要 macOS 15 或更新版本 / Setup requires macOS 15 or newer") }
        #if !arch(arm64)
        throw AppFailure("当前安装轨道仅支持 Apple 芯片 / This setup track requires Apple silicon")
        #endif
        guard !application.pathComponents.contains("AppTranslocation"),
              (try? application.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true else {
            throw AppFailure("请先将 Fluent Steam Mac 移到本机应用程序目录，以完成自动准备 / Move Fluent Steam Mac to Applications to finish preparation")
        }
        let p = resolveSteamPath(paths), status = RuntimeStatus.read(p)
        guard !RuntimeInstaller.backups(p).contains(where: \.interrupted) else { throw AppFailure("发现中断的安装，请先在安装与恢复中恢复备份 / Recover the interrupted installation before retrying") }
        let engine = application.appendingPathComponent("Contents/Resources/Helpers/SteamEngine/FluentSteamEngine")
        var result = Prepared(paths: p, options: options, awaitingFirstSteamLaunch: status.build.isEmpty)
        await progress("准备原生 Steam / Preparing native Steam…")
        if !status.steamInstalled { result.steam = try await NativeSteamBootstrap.prepare(cache: p.cache.appendingPathComponent("NativeSteam")) }
        else {
            let info = try PropertyListSerialization.propertyList(from: FileStore.read(p.steamApp.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == "com.valvesoftware.steam" else { throw AppFailure("所选应用不是原生 Steam / Selected app is not native Steam") }
        }
        for provider in ["macsteam", "notproton"] {
            let version = provider == "macsteam" ? status.macSteamVersion : status.notProtonVersion
            if preserveNewer(installed: version, candidate: ManagedRuntimeComponents.versions[provider]!) {
                guard status.injectedLibraries.contains(where: { $0.hasSuffix("/\(provider).dylib") }), status.missingLibraries.isEmpty else { throw AppFailure("\(provider) 的较新安装不完整，请更新 Fluent 后重试 / Update Fluent to repair the newer installation") }
                await progress("保留较新 \(provider) \(version) / Keeping newer installed component")
                continue
            }
            await progress("准备内置 \(provider) / Preparing bundled \(provider)…")
            let component = try await ManagedRuntimeComponents.prepare(provider: provider, paths: p, engine: engine, localApplication: provider == "macsteam" ? options.macSteamSource : options.notProtonSource, application: application)
            if provider == "macsteam" {
                if !status.build.isEmpty, !FileStore.fm.fileExists(atPath: component.resources.appendingPathComponent("signatures/macos.arm64/\(status.build).json").path) {
                    throw AppFailure("当前安装轨道尚未支持 Steam build \(status.build)，未修改内核 / This setup track does not support this Steam build; kernels unchanged")
                }
                result.macSteam = component
            } else { result.notProton = component }
        }
        return result
    }
    @discardableResult public static func seedConfiguration(paths: AppPaths, defaultTool: String?, requireIdle: () throws -> Void) throws -> URL? {
        var changes: [(URL, Data?)] = [], expected: [URL: String] = [:]
        if !FileStore.fm.fileExists(atPath: paths.config.path) {
            changes.append((paths.config, Data(MacSteamConfig().serialized().utf8))); expected[paths.config] = "missing"
        }
        if let defaultTool {
            guard try SteamCompatibility.tools(paths: paths).contains(where: { $0.id == defaultTool }) else { throw AppFailure("默认运行器尚未注册 / Default runtime is not registered") }
            let file = paths.steam.appendingPathComponent("config/config.vdf")
            let before = FileStore.fm.fileExists(atPath: file.path) ? try FileStore.read(file) : nil
            let after = try SteamCompatibility.seedDefault(before, tool: defaultTool)
            if before != after { changes.append((file, after)); expected[file] = before.map(FileStore.hash) ?? "missing" }
        }
        guard !changes.isEmpty else { return nil }
        let root = paths.data.appendingPathComponent("CompatibilityBackups")
        let record = try FileTransaction(backupRoot: root).apply(changes, reason: "首次配置 / Initial setup", expectations: expected, validate: requireIdle)
        return root.appendingPathComponent(record.id)
    }
    public static func install(_ prepared: Prepared, application: URL,
                               progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> SetupJournal {
        let p = prepared.paths
        try FileStore.mkdir(p.data.appendingPathComponent("Setup"))
        let lock = open(p.data.appendingPathComponent("Setup/install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw AppFailure("Cannot open setup lock") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("游戏环境正在准备 / Setup is already running") }
        var journal = SetupJournal(); journal.awaitingFirstSteamLaunch = prepared.awaitingFirstSteamLaunch
        func save() throws { try FileStore.json(journal, to: journalURL(p)) }
        func idle() throws { guard !SteamProcesses.isRunning else { throw AppFailure("等待 Steam 退出后继续；准备的组件已缓存 / Waiting for Steam to exit; prepared components are cached") } }
        func step(_ name: String, work: () async throws -> URL?) async throws {
            journal.step = name; journal.state = "installing"; try save(); await progress(name)
            try idle()
            if let backup = try await work() { journal.backups.append(backup.path) }
            journal.completed.append(name); try save()
        }
        do {
            try idle()
            if requiresRosetta(prepared), !(await rosettaAvailable()) { throw AppFailure("请先安装 Rosetta 2 / Install Rosetta 2 first") }
            if let steam = prepared.steam {
                try await step("安装原生 Steam / Installing native Steam") { try await NativeSteamBootstrap.install(steam, at: p.steamApp); return nil }
            }
            // A source manager can change during preparation; validate our owned
            // payload immediately before every deployment.
            if let component = prepared.macSteam {
                try ManagedRuntimeComponents.validate(component)
                try await step("安装 macSteam / Installing macSteam") {
                    try await RuntimeInstaller.run(paths: p, kernel: "macsteam.dylib", managedRoot: component.root, managedVersion: component.version, application: application, status: progress)
                }
            }
            if let component = prepared.notProton {
                try ManagedRuntimeComponents.validate(component)
                try await step("安装 NotProton / Installing NotProton") {
                    try await RuntimeInstaller.run(paths: p, kernel: "notproton.dylib", managedRoot: component.root, managedVersion: component.version, application: application, status: progress)
                }
                if component.version == "1.2.3" {
                    try await step("安装 NotProton 界面修复 / Installing NotProton UI repair") {
                        try await RuntimeInstaller.run(paths: p, kernel: "notproton.dylib", application: application, status: progress)
                    }
                }
            }
            for (kernel, resource) in [("cloud_redirect.dylib", "Cloud"), ("fluent_manifest.dylib", "Manifest")] {
                try await step("安装 \(resource) 扩展 / Installing \(resource) extension") {
                    try await RuntimeInstaller.run(paths: p, kernel: kernel, source: application.appendingPathComponent("Contents/Helpers/\(resource)/\(kernel)"), application: application, status: progress)
                }
            }
            try await step("保存内核配置 / Saving core configuration") { try seedConfiguration(paths: p, defaultTool: nil, requireIdle: idle) }
            guard RuntimeStatus.read(p).bothInjected else { throw AppFailure("内核安装验证未通过 / Runtime installation verification failed") }
            journal.state = "complete"; journal.step = ""; try save()
            return journal
        } catch {
            journal.state = "failed"; journal.error = error.localizedDescription
            // Include a helper-created backup even when the helper failed before
            // returning its path, so the recovery screen remains actionable.
            journal.backups += RuntimeInstaller.backups(p).filter { $0.date >= journal.started && !journal.backups.contains($0.folder.path) }.map { $0.folder.path }
            try? save(); throw error
        }
    }
}
