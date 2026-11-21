import Foundation

extension InstallerSelfTest {
    /// Only this test entry skips the running-client check and LaunchServices.
    /// Every mutable path is created here under a fresh temporary directory.
    static func managedIntegration(steam: String, mac: String, np: String, repair: String) async throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appending(path: "FluentManagedTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = false
        defer { if !passed { try? fm.removeItem(at: root) } }
        let support = root.appending(path: "Library/Application Support"), data = support.appending(path: "FluentSteamMac")
        let app = root.appending(path: "Applications/Steam.app")
        try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try InstallSnapshot.copy(URL(filePath: steam), to: app)
        var components: [String: URL] = [:]
        for (provider, path) in [("macsteam", mac), ("notproton", np)] {
            let target = data.appending(path: "Components/\(provider)/fixture")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try InstallSnapshot.copy(URL(filePath: path), to: target); components[provider] = target
        }
        var r = InstallRequest(companion: "/nonexistent-manager.app", steamApp: app.path,
            steamData: support.appending(path: "Steam").path, notProton: support.appending(path: "notproton").path,
            data: data.path, kernel: "macsteam.dylib", macSteam: support.appending(path: "macsteam").path,
            managedRoot: components["macsteam"]!.path, managedVersion: "0.8.2", rebuildExecutable: Bundle.main.executableURL!.path)
        _ = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        r.kernel = nil; r.managedRoot = components["notproton"]!.path; r.managedVersion = "1.2.3"
        _ = try await InstallSession.install(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        let info = app.appending(path: "Contents/Info.plist")
        let inserts = SteamBundle.currentInsert(at: info) ?? ""
        guard inserts.contains("/macsteam.dylib"), inserts.contains("/notproton.dylib"),
              try String(contentsOf: SupportPaths.support.appending(path: "app-executable"), encoding: .utf8) == Bundle.main.executableURL!.path,
              try String(contentsOf: SupportPaths.deployedVersion, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "1.2.3",
              try Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path]).succeeded else { throw StepFailure(step: "Test", detail: "Managed installation verification failed") }
        print("PASS: native Steam + managed macSteam + managed NotProton deployed without any companion app path")
        print("PASS: prefix rebuild points to our bundled executable")
        let before = try InstallSnapshot.digest(app), beforeSupport = try InstallSnapshot.digest(SupportPaths.support)
        final class FailureProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var checks = 0
            func check() throws {
                lock.lock(); defer { lock.unlock() }
                checks += 1
                if checks == 3 { throw StepFailure(step: "Injected", detail: "Synthetic post-deploy failure") }
            }
        }
        let probe = FailureProbe()
        do {
            _ = try await InstallSession.install(r, requireIdle: {
                try probe.check()
            }, register: { _ in }, progress: { _ in })
            throw StepFailure(step: "Test", detail: "Failure injection did not execute")
        } catch let error as StepFailure { guard error.step == "Injected" else { throw error } }
        guard try InstallSnapshot.digest(app) == before, try InstallSnapshot.digest(SupportPaths.support) == beforeSupport else { throw StepFailure(step: "Test", detail: "Rollback changed installed files") }
        print("PASS: an injected installation failure restores Steam and NotProton exactly")
        r.kernel = "notproton.dylib"; r.source = repair; r.managedRoot = nil; r.managedVersion = nil
        _ = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        print("PASS: bundled NotProton UI repair deployed into managed installation")
        r.kernel = nil; r.managedRoot = components["notproton"]!.path; r.managedVersion = "1.2.3"
        let extra = components["notproton"]!.appending(path: "unexpected")
        try Data("tamper".utf8).write(to: extra)
        do { try ManagedPayload.validate(r, provider: "notproton"); throw StepFailure(step: "Test", detail: "Unlisted component accepted") }
        catch let error as StepFailure { guard error.step == "Components" else { throw error } }
        try fm.removeItem(at: extra)
        print("PASS: managed helper rejects files missing from the component receipt")
        try Data("Fluent managed installation fixture\n".utf8).write(to: root.appending(path: ".fluent-setup-test"))
        passed = true; return root.path
    }
}
