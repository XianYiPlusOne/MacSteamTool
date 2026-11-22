import Foundation
import MacSteamToolCore

enum SetupValidation {
    /// Real installation code with generated, disposable destinations. Neither
    /// the real Steam app nor the user's Application Support is ever a target.
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 6 else { throw AppFailure("validate-setup APP_BUNDLE MACSTEAM_APP NOTPROTON_APP STEAM_DMG FREE_DMG") }
        let application = URL(fileURLWithPath: arguments[1])
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentSetupValidation-\(UUID().uuidString)")
        try FileStore.mkdir(root)
        var succeeded = false
        defer {
            if succeeded { try? FileStore.fm.removeItem(at: root) }
            else { print("Failed fixture retained for diagnosis: \(root.path)") }
        }
        var p = AppPaths(home: root); p.steamApp = root.appendingPathComponent("Applications/Steam.app")
        let steam = try await NativeSteamBootstrap.prepare(cache: p.cache.appendingPathComponent("NativeSteam"), archive: arguments[4] == "-" ? nil : URL(fileURLWithPath: arguments[4]))
        try await NativeSteamBootstrap.install(steam, at: p.steamApp)
        print("PASS: official Valve-signed Steam installer bootstrapped into empty fixture")
        let mac = try await ManagedRuntimeComponents.prepare(provider: "macsteam", paths: p, localApplication: arguments[2] == "-" ? nil : URL(fileURLWithPath: arguments[2]), application: application)
        let np = try ManagedRuntimeComponents.prepareCrossOver(paths: p, application: application)
        print("PASS: source-built integrations copied from MacSteamTool, without upstream app downloads")
        let helper = application.appendingPathComponent("Contents/Helpers/NotProton/MacSteamToolNotProton")
        let repair = application.appendingPathComponent("Contents/Resources/Helpers/NotProtonRepair/notproton.dylib")
        let (code, output) = try await ProcessRunner.run(helper, ["--test-managed", p.steamApp.path, mac.root.path, np.root.path, repair.path])
        print(output)
        guard code == 0, let line = output.split(separator: "\n").last,
              let report = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String], let path = report["fixture"] else { throw AppFailure("Managed deployment integration test failed") }
        let deployed = URL(fileURLWithPath: path).standardizedFileURL
        guard deployed.deletingLastPathComponent() == FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL,
              deployed.lastPathComponent.hasPrefix("FluentManagedTest-"), FileStore.fm.fileExists(atPath: deployed.appendingPathComponent(".fluent-setup-test").path) else { throw AppFailure("Invalid fixture result") }
        try await finish(application: application, fixture: deployed, archive: URL(fileURLWithPath: arguments[5]))
        succeeded = true
    }
    static func finish(application: URL, fixture deployed: URL, archive: URL) async throws {
        guard deployed.deletingLastPathComponent().resolvingSymlinksInPath() == FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL,
              deployed.lastPathComponent.hasPrefix("FluentManagedTest-"), FileStore.fm.fileExists(atPath: deployed.appendingPathComponent(".fluent-setup-test").path) else { throw AppFailure("Invalid fixture result") }
        var succeeded = false
        defer { if succeeded { try? FileStore.fm.removeItem(at: deployed) } }
        var installed = AppPaths(home: deployed); installed.steamApp = deployed.appendingPathComponent("Applications/Steam.app")
        // Exercise the same FreeRuntime installation, bypassing only the global
        // client-running check for this generated fixture. No fixture is launched.
        try await FreeRuntime.install(paths: installed, resources: application.appendingPathComponent("Contents/Resources/FreeRuntime"), archive: archive, steamRunning: { false }, progress: { print($0) })
        _ = try OneClickSetup.seedConfiguration(paths: installed, defaultTool: FreeRuntime.toolID, requireIdle: {})
        guard RuntimeStatus.read(installed).bothInjected, FreeRuntime.installedRoot(installed) != nil,
              try SteamCompatibility.globalTool(FileStore.read(installed.steam.appendingPathComponent("config/config.vdf"))) == FreeRuntime.toolID else { throw AppFailure("Fresh setup final state did not verify") }
        print("PASS: native Steam + both managed kernels + free runtime + first configuration verified together")
        print("PASS: isolated fixture completed without closing or changing the real Steam installation")
        succeeded = true
    }
}
