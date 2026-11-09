import Foundation

extension InstallerSelfTest {
    static func notProtonRepair(source: String) throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "FluentRepairTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appending(path: "Steam.app"), contents = app.appending(path: "Contents/MacOS"), support = root.appending(path: "notproton")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: "/bin/echo"), to: contents.appending(path: "steam_osx"))
        try Data("old-kernel".utf8).write(to: contents.appending(path: "notproton.dylib"))
        let env: [String: String] = [SteamBundle.insertKey: "/test/macsteam.dylib:/test/cloud_redirect.dylib:/test/notproton.dylib", SteamBundle.controllerBlockKey: SteamBundle.controllerBlockValue, "UNRELATED": "keep"]
        let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx", "CFBundlePackageType": "APPL", SteamBundle.environmentKey: env]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let version = support.appending(path: "dylib.version")
        try Data("1.2.4\n".utf8).write(to: version)
        let initial = try InstallSnapshot.digest(app)
        var r = InstallRequest(companion: "", steamApp: app.path, steamData: root.appending(path: "SteamData").path, notProton: support.path, data: root.appending(path: "manager").path, kernel: "notproton.dylib", source: source)
        do { _ = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in }); throw StepFailure(step: "Test", detail: "repair downgraded 1.2.4") }
        catch let failure as StepFailure { guard failure.step != "Test" else { throw failure } }
        guard try InstallSnapshot.digest(app) == initial else { throw StepFailure(step: "Test", detail: "version rejection mutated Steam") }
        print("PASS: newer NotProton rejected before mutation")
        try Data("1.2.3\n".utf8).write(to: version)
        let payload = root.appending(path: "payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: source), to: payload.appending(path: "notproton.dylib"))
        try Data("{}".utf8).write(to: payload.appending(path: "fluent-notproton-repair.json"))
        r.source = payload.appending(path: "notproton.dylib").path
        do { _ = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in }); throw StepFailure(step: "Test", detail: "accepted invalid receipt") }
        catch let failure as StepFailure { guard failure.step != "Test" else { throw failure } }
        guard try InstallSnapshot.digest(app) == initial else { throw StepFailure(step: "Test", detail: "receipt rejection mutated Steam") }
        print("PASS: invalid receipt rejected before mutation")
        r.source = source
        let supportBefore = try InstallSnapshot.digest(support)
        let backup = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        let updated = SteamBundle.readInfoPlist(at: app.appending(path: "Contents/Info.plist"))?[SteamBundle.environmentKey] as? [String: String]
        guard updated?["UNRELATED"] == "keep", updated?[SteamBundle.controllerBlockKey] == SteamBundle.controllerBlockValue,
              updated?[SteamBundle.insertKey] == "/test/macsteam.dylib:/test/cloud_redirect.dylib:" + contents.appending(path: "notproton.dylib").path,
              try InstallSnapshot.digest(support) == supportBefore,
              try Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path]).succeeded else { throw StepFailure(step: "Test", detail: "repair scope or signature mismatch") }
        print("PASS: repair installed and signed; other modules, environment and support tree preserved")
        r.backup = backup
        _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard try InstallSnapshot.digest(app) == initial, try InstallSnapshot.digest(support) == supportBefore else { throw StepFailure(step: "Test", detail: "repair restore mismatch") }
        print("PASS: complete repair rollback restores original bundle and leaves runtime data unchanged")
    }
}
