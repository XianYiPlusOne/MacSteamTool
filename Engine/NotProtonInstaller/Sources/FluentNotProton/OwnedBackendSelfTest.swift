import Foundation

extension InstallerSelfTest {
    /// Exercise actual licensed runner cloning, patching and registration in an
    /// empty generated support directory. Does not alter Steam or CrossOver.
    static func ownedBackend(application: String, crossOver: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appending(path: "FluentOwnedBackend-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = root.appending(path: "FluentSteamMac")
        let component = data.appending(path: "Components/notproton/crossover-1.2.3")
        try fm.createDirectory(at: component.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: application).appending(path: "Contents/Resources/RuntimeBackends/crossover"), to: component)
        let request = InstallRequest(companion: "/nonexistent-NotProton.app", steamApp: root.appending(path: "Steam.app").path,
            steamData: root.appending(path: "Steam").path, notProton: root.appending(path: "notproton").path, data: data.path,
            managedRoot: component.path, managedVersion: "1.2.3", rebuildExecutable: Bundle.main.executableURL!.path)
        try InstallSession.configure(request)
        try InstallSession.resources(request)
        let payload = try InstallPayload.locate()
        let bridge = try BridgePayload.locate()
        _ = try BridgePayload.stage(located: bridge)
        let install = CrossOverSource.inspect(bundle: URL(filePath: crossOver), isManual: true)
        let outcome = try RunnerSetup.run(from: install)
        let tools = CompatToolList.installed()
        guard !tools.isEmpty, !outcome.staged.isEmpty else {
            throw StepFailure(step: "Test", detail: "Owned CrossOver adapter did not register and patch the runner")
        }
        for tool in tools {
            let run = SupportPaths.Steam.compatTools.appending(path: "\(tool.name)/run")
            guard Digest.sha256IfPresent(run) == Digest.sha256IfPresent(payload.run) else {
                throw StepFailure(step: "Test", detail: "Runner launcher is not Fluent's maintained source")
            }
        }
        print("PASS: Fluent-built bridge and launchers validate without upstream apps")
        print("PASS: purchased CrossOver cloned, license validated, native bridge patched and compatibility tools registered in an empty fixture")
        print("PASS: original CrossOver and live Steam are not installation targets")
    }
}
