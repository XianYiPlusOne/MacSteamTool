import Foundation

extension InstallerSelfTest {
    /// Native-only deployment: all destinations are generated here. No manager,
    /// Wine, CrossOver, Valve package fetch, or real Steam state participates.
    static func coreIntegration(application: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appending(path: "FluentCoreTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appending(path: "Library/Application Support"), data = support.appending(path: "MacSteamTool")
        let app = root.appending(path: "Steam.app"), executable = app.appending(path: "Contents/MacOS/steam_osx")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx", "CFBundlePackageType": "APPL", "LSEnvironment": ["OTHER": "keep"]]
        let info = app.appending(path: "Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        let initial = try InstallSnapshot.digest(app)
        var components: [String: URL] = [:]
        for (provider, version) in [("macsteam", "0.8.2"), ("notproton", "1.2.3")] {
            let target = data.appending(path: "Components/\(provider)/bundled-\(version)")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try InstallSnapshot.copy(URL(filePath: application).appending(path: "Contents/Resources/RuntimeComponents/\(provider)/\(version)"), to: target)
            components[provider] = target
        }
        var r = InstallRequest(companion: "/nonexistent-manager.app", steamApp: app.path,
            steamData: support.appending(path: "Steam").path, notProton: support.appending(path: "notproton").path,
            data: data.path, kernel: "macsteam.dylib", macSteam: support.appending(path: "macsteam").path,
            managedRoot: components["macsteam"]!.path, managedVersion: "0.8.2", rebuildExecutable: Bundle.main.executableURL!.path)
        let macBackup = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        let macOnly = try InstallSnapshot.digest(app)
        r.kernel = "notproton.dylib"; r.managedRoot = components["notproton"]!.path; r.managedVersion = "1.2.3"
        let npBackup = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        let inserts = SteamBundle.currentInsert(at: info) ?? ""
        guard inserts.contains("/macsteam.dylib"), inserts.contains("/notproton.dylib"),
              try String(contentsOf: SupportPaths.deployedVersion, encoding: .utf8) == "1.2.3\n",
              try String(contentsOf: SupportPaths.support.appending(path: "app-executable"), encoding: .utf8) == Bundle.main.executableURL!.path,
              try Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path]).succeeded else {
            throw StepFailure(step: "Test", detail: "Bundled core deployment did not verify")
        }
        let env = SteamBundle.readInfoPlist(at: info)?[SteamBundle.environmentKey] as? [String: String]
        guard env?["OTHER"] == "keep", env?[SteamBundle.controllerBlockKey] == SteamBundle.controllerBlockValue else {
            throw StepFailure(step: "Test", detail: "Steam environment not preserved/configured")
        }
        for path in [SupportPaths.bridge, SupportPaths.fonts, SupportPaths.runners, SupportPaths.Steam.compatTools, data.appending(path: "FreeRuntime"), SupportPaths.packageDownloads] {
            guard !fm.fileExists(atPath: path.path) else { throw StepFailure(step: "Test", detail: "Core setup unexpectedly created backend files: \(path.lastPathComponent)") }
        }
        print("PASS: bundled macSteam + NotProton install into an empty native Steam fixture without managers or translation backends")
        print("PASS: core setup creates no Wine, CrossOver, bridges, fonts, Valve downloads or compatibility tools")
        // Verify the production automatic health check against actual signed
        // deployments, then undo these supplemental fixture-only steps.
        let nativeRequest = r
        var extraBackups: [String] = []
        r.managedRoot = nil; r.managedVersion = nil
        for (name, relative) in [("notproton.dylib", "Contents/Resources/Helpers/NotProtonRepair/notproton.dylib"),
                                 ("cloud_redirect.dylib", "Contents/Helpers/Cloud/cloud_redirect.dylib"),
                                 ("fluent_manifest.dylib", "Contents/Helpers/Manifest/manifest.dylib")] {
            r.kernel = name; r.source = URL(filePath: application).appending(path: relative).path
            extraBackups.append(try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in }))
        }
        try Data("# fixture configuration\n".utf8).write(to: support.appending(path: "macsteam/config.yaml"))
        let cli = URL(filePath: application).appending(path: "Contents/MacOS/MacSteamToolRuntime")
        let health = try Shell.run(cli.path, ["integration-status", application, root.path])
        guard health.succeeded, health.stdout.contains("Integration ready") else { throw StepFailure(step: "Test", detail: "Automatic inspection rejects a complete real deployment: \(health.stdout)") }
        print("PASS: production health check recognizes the signed deployment as ready, preventing repeated automatic installation")
        for backup in extraBackups.reversed() {
            r.backup = backup
            _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        }
        r = nativeRequest
        // Existing runner, prefix and manual configuration must remain byte-identical.
        for relative in ["Steam/config/config.vdf", "Steam/steamapps/compatdata/123/pfx/save", "notproton/runners/crossover-existing/sentinel"] {
            let file = support.appending(path: relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep-existing-data".utf8).write(to: file)
        }
        let beforeApp = try InstallSnapshot.digest(app), beforeNP = try InstallSnapshot.digest(SupportPaths.support), beforeSteam = try InstallSnapshot.digest(SupportPaths.Steam.userData)
        _ = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        guard try InstallSnapshot.digest(SupportPaths.support) == beforeNP, try InstallSnapshot.digest(SupportPaths.Steam.userData) == beforeSteam else {
            throw StepFailure(step: "Test", detail: "Core repair modified existing runtime data")
        }
        print("PASS: core repair preserves existing runtime choices, runner files and game saves")
        var checks = 0
        do {
            _ = try InstallSession.kernel(r, requireIdle: {
                checks += 1
                if checks == 3 { throw StepFailure(step: "Injected", detail: "Failure after support deployment") }
            }, register: { _ in }, progress: { _ in })
            throw StepFailure(step: "Test", detail: "Failure injection did not execute")
        } catch let error as StepFailure { guard error.step == "Injected" else { throw error } }
        guard try InstallSnapshot.digest(app) == beforeApp, try InstallSnapshot.digest(SupportPaths.support) == beforeNP else {
            throw StepFailure(step: "Test", detail: "Failed core installation did not restore exactly")
        }
        print("PASS: failure after support writes rolls back both Steam and native core resources")
        r.backup = npBackup
        _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard try InstallSnapshot.digest(app) == macOnly, !fm.fileExists(atPath: SupportPaths.deployedVersion.path),
              try InstallSnapshot.digest(SupportPaths.Steam.userData) == beforeSteam else { throw StepFailure(step: "Test", detail: "NotProton core restore failed") }
        r.backup = macBackup
        _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard try InstallSnapshot.digest(app) == initial else { throw StepFailure(step: "Test", detail: "macSteam core restore failed") }
        print("PASS: both core backups restore the original Steam bundle; unrelated games and runners survive")
    }
}
