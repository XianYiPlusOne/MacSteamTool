import Foundation

enum InstallerSelfTest {
    static func run() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "FluentInstallerTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func check(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
            guard try condition() else { throw StepFailure(step: "Test", detail: detail) }; print("PASS: \(detail)")
        }
        let plist = root.appending(path: "Info.plist")
        let env = ["DYLD_INSERT_LIBRARIES": "/old/notproton.dylib:/test/macsteam.dylib:/test/cloud_redirect.dylib", "OTHER": "keep"]
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.valvesoftware.steam", "LSEnvironment": env], format: .xml, options: 0).write(to: plist)
        try SteamInstaller.setInsert(at: plist, to: URL(filePath: "/new/notproton.dylib"))
        try check(SteamBundle.currentInsert(at: plist) == "/test/macsteam.dylib:/test/cloud_redirect.dylib:/new/notproton.dylib", "NotProton update preserves macSteam / CloudRedirect inserts")
        try check((SteamBundle.readInfoPlist(at: plist)?["LSEnvironment"] as? [String: String])?["OTHER"] == "keep", "unrelated launch environment preserved")
        try SteamInstaller.setInsert(at: plist, to: URL(filePath: "/new/notproton.dylib"))
        try check(SteamBundle.currentInsert(at: plist)?.components(separatedBy: "notproton.dylib").count == 2, "repeated deployment does not duplicate insert")
        let original = root.appending(path: "installation"), missing = root.appending(path: "created/later"), backup = root.appending(path: "backup")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let file = original.appending(path: "binary")
        let binary = Data([0,255,2,3,0]); try binary.write(to: file)
        try fm.createSymbolicLink(atPath: original.appending(path: "link").path, withDestinationPath: "binary")
        let snapshot = try InstallSnapshot.capture([original, missing], in: backup)
        try Data("updated".utf8).write(to: file)
        try fm.createDirectory(at: missing, withIntermediateDirectories: true)
        try snapshot.recordInstalled(in: backup); try snapshot.verifyInstalled(in: backup)
        try Data("external update".utf8).write(to: file)
        do { try snapshot.verifyInstalled(in: backup); throw StepFailure(step: "Test", detail: "accepted changed installation") }
        catch let failure as StepFailure { guard failure.step != "Test" else { throw failure } }
        print("PASS: recovery refuses an installation modified since deployment")
        try snapshot.restore(from: backup)
        try check(Data(contentsOf: file) == binary && !fm.fileExists(atPath: missing.path), "rollback restores binary content and removes newly created tree")
        try check(fm.destinationOfSymbolicLink(atPath: original.appending(path: "link").path) == "binary", "rollback preserves symbolic links without following them")
        try Data("damaged".utf8).write(to: backup.appending(path: "0/binary"))
        do { try snapshot.restore(from: backup); throw StepFailure(step: "Test", detail: "accepted damaged backup") }
        catch let failure as StepFailure { guard failure.step != "Test" else { throw failure } }
        try check(Data(contentsOf: file) == binary, "damaged backup rejected before original changes")
        let lock = try DeploymentContent.acquireInstallationLock(in: root, steamFolder: nil)
        do {
            let second = try DeploymentContent.acquireInstallationLock(in: root, steamFolder: nil); second.release()
            throw StepFailure(step: "Test", detail: "accepted concurrent installation")
        } catch let failure as StepFailure { guard failure.step != "Test" else { lock.release(); throw failure } }
        lock.release(); print("PASS: shared installation lock refuses competing installer")
    }
    static func kernelIntegration(companion: String) throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "FluentKernelTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        let app = root.appending(path: "Steam.app"), contents = app.appending(path: "Contents/MacOS")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(filePath: "/usr/bin/true"), to: contents.appending(path: "steam_osx"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx", "CFBundlePackageType": "APPL", "LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/test/notproton.dylib:/test/cloud_redirect.dylib", "OTHER": "keep"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let initial = try InstallSnapshot.digest(app)
        var r = InstallRequest(companion: companion, steamApp: app.path, steamData: root.appending(path: "SteamData").path, notProton: root.appending(path: "notproton").path, data: root.appending(path: "manager").path, kernel: "macsteam.dylib", macSteam: root.appending(path: "macsteam").path)
        // Only this fixture entry bypasses the global running-client check; roots are created above.
        let backup = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        guard fm.fileExists(atPath: contents.appending(path: "macsteam.dylib").path), SteamBundle.currentInsert(at: app.appending(path: "Contents/Info.plist")) == "/test/notproton.dylib:/test/cloud_redirect.dylib:" + contents.appending(path: "macsteam.dylib").path,
              fm.fileExists(atPath: root.appending(path: "macsteam/signatures/macos.arm64").path), try Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path]).succeeded else { throw StepFailure(step: "Test", detail: "macSteam deployment did not land") }
        print("PASS: actual macSteam companion payload deployed and signed into isolated Steam fixture; other inserts preserved")
        r.backup = backup
        _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard try InstallSnapshot.digest(app) == initial, !fm.fileExists(atPath: root.appending(path: "macsteam/dylib.version").path), !fm.fileExists(atPath: root.appending(path: "macsteam/signatures").path) else { throw StepFailure(step: "Test", detail: "macSteam rollback mismatch") }
        print("PASS: installation restore returns fixture bundle and resource trees to original contents")
        let interrupted = URL(filePath: r.data).appending(path: "RuntimeBackups/Kernel-\(UUID().uuidString)")
        _ = try InstallSnapshot.capture([app], in: interrupted)
        let partial = contents.appending(path: "partial-install.bin")
        try Data("interrupted-state".utf8).write(to: partial)
        let partialDigest = try InstallSnapshot.digest(app)
        r.backup = interrupted.path
        do { _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in }); throw StepFailure(step: "Test", detail: "accepted incomplete deployment without recovery selection") }
        catch let failure as StepFailure { guard failure.step != "Test" else { throw failure } }
        catch { /* missing installed receipt is correctly rejected */ }
        r.recoverInterrupted = true
        let preserved = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard try InstallSnapshot.digest(app) == initial,
              try InstallSnapshot.digest(URL(filePath: preserved).appending(path: "0")) == partialDigest else { throw StepFailure(step: "Test", detail: "interrupted recovery did not preserve both states") }
        print("PASS: interrupted deployment recovery restores original and preserves the entire partial state in a second backup")
        r.backup = preserved; r.recoverInterrupted = false
        _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard try InstallSnapshot.digest(app) == partialDigest else { throw StepFailure(step: "Test", detail: "cannot undo interrupted recovery") }
        print("PASS: interrupted recovery can itself be undone using its retained backup")
        try fm.removeItem(at: partial)
        let cleanupInitial = try InstallSnapshot.digest(app)
        r.kernel = "notproton.dylib"; r.remove = true; r.cleanRunners = true; r.backup = nil
        let runner = URL(filePath: r.notProton).appending(path: "runners/crossover-fixture/CrossOver/lib/wine")
        let bridge = URL(filePath: r.notProton).appending(path: "bridge")
        let compat = URL(filePath: r.steamData).appending(path: "compatibilitytools.d/notproton-fixture")
        for directory in [runner, bridge, compat] { try fm.createDirectory(at: directory, withIntermediateDirectories: true); try Data("fixture".utf8).write(to: directory.appending(path: "sentinel")) }
        let other = URL(filePath: r.steamData).appending(path: "compatibilitytools.d/other-tool")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let cleanBackup = try InstallSession.kernel(r, requireIdle: {}, register: { _ in }, progress: { _ in })
        guard !fm.fileExists(atPath: runner.path), !fm.fileExists(atPath: compat.path), fm.fileExists(atPath: other.path) else { throw StepFailure(step: "Test", detail: "runner cleanup scope mismatch") }
        r.backup = cleanBackup
        _ = try InstallSession.restoreKernel(r, requireIdle: {}, register: { _ in })
        guard fm.fileExists(atPath: runner.appending(path: "sentinel").path), fm.fileExists(atPath: compat.appending(path: "sentinel").path), try InstallSnapshot.digest(app) == cleanupInitial else { throw StepFailure(step: "Test", detail: "runner cleanup restoration mismatch") }
        print("PASS: runner/bridge cleanup and restoration preserve unrelated compatibility tools")
    }

}
