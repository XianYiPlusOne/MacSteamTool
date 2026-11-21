import Foundation
import CryptoKit

extension InstallSession {
    static var notProtonCoreTargets: [URL] {
        [SupportPaths.deployedVersion, SupportPaths.support.appending(path: "signatures"), SupportPaths.overlayShim,
         SupportPaths.iconmaker, SupportPaths.appinfo, SupportPaths.support.appending(path: RebuildPrefixCommand.executableRecord)]
    }
    static func kernel(_ r: InstallRequest, requireIdle: () throws -> Void = InstallSession.requireIdle, register: (URL) -> Void = SteamBundle.register, progress: @escaping @Sendable (String) -> Void) throws -> String {
        try configure(r); try requireIdle()
        guard let kernel = r.kernel, ["macsteam.dylib", "cloud_redirect.dylib", "notproton.dylib", "fluent_manifest.dylib"].contains(kernel),
              SteamBundle.readInfoPlist(at: SupportPaths.Steam.infoPlist)?["CFBundleIdentifier"] as? String == "com.valvesoftware.steam" else {
            throw StepFailure(step: "Install kernel", detail: "Invalid kernel or Steam bundle")
        }
        let fm = FileManager.default, app = SupportPaths.Steam.app
        let lock = try DeploymentContent.acquireInstallationLock(in: SupportPaths.applicationSupport, steamFolder: app.deletingLastPathComponent()); defer { lock.release() }
        var source: URL?, extras: [(URL, URL)] = []
        let metadata = fm.temporaryDirectory.appending(path: "FluentCoreMetadata-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: metadata) }
        if r.remove != true {
            if kernel == "macsteam.dylib" {
                guard let support = r.macSteam, support.hasPrefix("/"), support != "/" else { throw StepFailure(step: "Install macSteam", detail: "Missing macSteam support path") }
                let resources: URL
                if let root = r.managedRoot {
                    try ManagedPayload.validate(r, provider: "macsteam")
                    resources = URL(filePath: root).appending(path: "Resources")
                } else {
                    guard let bundle = Bundle(path: r.companion), bundle.bundleIdentifier == "com.macsteam.app" else { throw StepFailure(step: "Install macSteam", detail: "Choose the official macSteam Config.app") }
                    resources = URL(filePath: r.companion).appending(path: "Contents/Resources")
                }
                source = resources.appending(path: kernel)
                extras = [(resources.appending(path: "macsteam.dylib.version"), URL(filePath: support).appending(path: "dylib.version")), (resources.appending(path: "signatures"), URL(filePath: support).appending(path: "signatures"))]
                for (from, _) in extras where !fm.fileExists(atPath: from.path) { throw StepFailure(step: "Install macSteam", detail: "Missing resource: \(from.lastPathComponent)") }
            } else if kernel == "notproton.dylib", let root = r.managedRoot {
                try ManagedPayload.validate(r, provider: "notproton")
                let payload = URL(filePath: root).appending(path: "NotProtonRuntime.bundle/Contents/Resources/payload")
                source = payload.appending(path: kernel)
                guard let executable = r.rebuildExecutable, executable.hasPrefix("/"), fm.isExecutableFile(atPath: executable) else {
                    throw StepFailure(step: "Install NotProton core", detail: "Missing bundled prefix rebuild helper")
                }
                try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
                try Data((r.managedVersion! + "\n").utf8).write(to: metadata.appending(path: "version"))
                try RebuildPrefixCommand.recordExecutable(URL(filePath: executable), in: metadata)
                guard try String(contentsOf: metadata.appending(path: RebuildPrefixCommand.executableRecord), encoding: .utf8) == executable else {
                    throw StepFailure(step: "Install NotProton core", detail: "Cannot record bundled prefix rebuild helper")
                }
                let sources = [metadata.appending(path: "version"), payload.appending(path: "signatures"), payload.appending(path: "overlay-shim.dylib"),
                               payload.appending(path: "iconmaker"), payload.appending(path: "appinfo"), metadata.appending(path: RebuildPrefixCommand.executableRecord)]
                extras = Array(zip(sources, notProtonCoreTargets))
                for (from, _) in extras where !fm.fileExists(atPath: from.path) {
                    throw StepFailure(step: "Install NotProton core", detail: "Missing core resource: \(from.lastPathComponent)")
                }
            } else {
                guard let path = r.source, path.hasPrefix("/") else { throw StepFailure(step: "Install kernel", detail: "Missing bundled kernel") }
                source = URL(filePath: path)
            }
            guard let source, try Shell.run("/usr/bin/lipo", ["-archs", source.path]).stdout.contains("arm64") else { throw StepFailure(step: "Install kernel", detail: "Kernel must support ARM64") }
            if kernel == "notproton.dylib", r.managedRoot == nil { try validateNotProtonRepair(source) }
        }
        guard r.cleanRunners != true || (kernel == "notproton.dylib" && r.remove == true) else { throw StepFailure(step: "Remove runners", detail: "Runner cleanup requires NotProton removal") }
        let cleanup = r.cleanRunners == true ? [SupportPaths.runners, SupportPaths.bridge, SupportPaths.toolList] + SupportPaths.Steam.notprotonTools() : []
        let roots = [app] + extras.map(\.1) + cleanup
        let backup = URL(filePath: r.data).appending(path: "RuntimeBackups/Kernel-\(UUID().uuidString)")
        progress("Backing up Steam and kernel resources")
        let snapshot = try InstallSnapshot.capture(roots, in: backup)
        let stage = app.deletingLastPathComponent().appending(path: ".FluentSteam-stage-\(UUID().uuidString).app")
        let holding = app.deletingLastPathComponent().appending(path: ".FluentSteam-original-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stage) }
        try InstallSnapshot.copy(app, to: stage)
        let plistURL = stage.appending(path: "Contents/Info.plist")
        guard var plist = SteamBundle.readInfoPlist(at: plistURL) else { throw StepFailure(step: "Install kernel", detail: "Cannot read Steam Info.plist") }
        var env = plist[SteamBundle.environmentKey] as? [String: Any] ?? [:]
        var libraries = (env[SteamBundle.insertKey] as? String ?? "").split(separator: ":").map(String.init).filter { URL(filePath: $0).lastPathComponent != kernel }
        let stagedLibrary = stage.appending(path: "Contents/MacOS/" + kernel)
        if fm.fileExists(atPath: stagedLibrary.path) { try fm.removeItem(at: stagedLibrary) }
        if let source {
            try fm.copyItem(at: source, to: stagedLibrary); try SteamInstaller.adHocSign(stagedLibrary)
            libraries.append(app.appending(path: "Contents/MacOS/" + kernel).path)
        }
        if libraries.isEmpty { env.removeValue(forKey: SteamBundle.insertKey) } else { env[SteamBundle.insertKey] = libraries.joined(separator: ":") }
        if kernel == "notproton.dylib", r.remove == true, env[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue { env.removeValue(forKey: SteamBundle.controllerBlockKey) }
        if kernel == "notproton.dylib", r.remove != true { env[SteamBundle.controllerBlockKey] = SteamBundle.controllerBlockValue }
        if kernel == "fluent_manifest.dylib" {
            if r.remove == true {
                for key in ["FLUENT_PINS_CONFIG", "FLUENT_PINS_CACHE", "FLUENT_PINS_STATUS"] { env.removeValue(forKey: key) }
            } else {
                guard let support = r.macSteam, support.hasPrefix("/"), support != "/" else { throw StepFailure(step: "Manifest extension", detail: "Missing macSteam configuration path") }
                env["FLUENT_PINS_CONFIG"] = URL(filePath: support).appending(path: "config.yaml").path
                env["FLUENT_PINS_CACHE"] = URL(filePath: r.steamData).appending(path: "depotcache").path
                env["FLUENT_PINS_STATUS"] = URL(filePath: r.data).appending(path: "manifest-pins.log").path
            }
        }
        if kernel == "cloud_redirect.dylib" {
            if r.remove == true {
                env.removeValue(forKey: "FLUENT_CLOUD_ROOT"); env.removeValue(forKey: "FLUENT_CLOUD_STEAM")
            } else {
                env["FLUENT_CLOUD_ROOT"] = r.data; env["FLUENT_CLOUD_STEAM"] = r.steamData
            }
        }
        if env.isEmpty { plist.removeValue(forKey: SteamBundle.environmentKey) } else { plist[SteamBundle.environmentKey] = env }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL, options: .atomic)
        progress("Signing and verifying Steam")
        try SteamInstaller.adHocSign(stage.appending(path: "Contents/MacOS/steam_osx")); try SteamInstaller.adHocSign(stage)
        guard try Shell.run("/usr/bin/codesign", ["--verify", "--strict", stage.path]).succeeded else { throw StepFailure(step: "Verify", detail: "Steam bundle signature verification failed") }
        try requireIdle()
        guard try InstallSnapshot.digest(app) == snapshot.items[0].sha256 else { throw StepFailure(step: "Install kernel", detail: "Steam changed while preparing the installation") }
        do {
            for (from, to) in extras {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
            try requireIdle()
            try fm.moveItem(at: app, to: holding)
            do { try fm.moveItem(at: stage, to: app) } catch { try fm.moveItem(at: holding, to: app); throw error }
            for path in cleanup where fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
            try snapshot.recordInstalled(in: backup)
            try Data("complete\n".utf8).write(to: backup.appending(path: "status"), options: .atomic)
        } catch {
            let original = error
            try? InstallSnapshot.mark("recovery-needed", in: backup)
            do { try requireIdle(); try snapshot.restore(from: backup, beforeMutation: requireIdle); try InstallSnapshot.mark("restored", in: backup) }
            catch { throw StepFailure(step: "Recovery needed", detail: "\(original.localizedDescription). Recovery: \(error.localizedDescription). Backup: \(backup.path)") }
            throw original
        }
        try? fm.removeItem(at: holding)
        register(app)
        return backup.path
    }
    private static func validateNotProtonRepair(_ source: URL) throws {
        let version = try String(contentsOf: SupportPaths.deployedVersion, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == "1.2.3", FileManager.default.fileExists(atPath: SupportPaths.Steam.app.appending(path: "Contents/MacOS/notproton.dylib").path) else {
            throw StepFailure(step: "Repair NotProton", detail: "This repair requires an existing NotProton 1.2.3 installation; runners and profiles will not be downgraded")
        }
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: source.deletingLastPathComponent().appending(path: "fluent-notproton-repair.json"))) as? [String: String]
        let hash = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        guard receipt?["upstream"] == "692b470e73d0d497ee9e474038efda819a037772", receipt?["repair"] == "webui-capacity-1", receipt?["sha256"] == hash,
              try Shell.run("/usr/bin/codesign", ["--verify", "--strict", source.path]).succeeded else {
            throw StepFailure(step: "Repair NotProton", detail: "NotProton repair payload or receipt verification failed")
        }
    }
    static func restoreKernel(_ r: InstallRequest, requireIdle: () throws -> Void = InstallSession.requireIdle, register: (URL) -> Void = SteamBundle.register) throws -> String {
        try configure(r); try requireIdle()
        guard let path = r.backup, URL(filePath: path).deletingLastPathComponent().standardizedFileURL.path == URL(filePath: r.data).appending(path: "RuntimeBackups").standardizedFileURL.path, URL(filePath: path).lastPathComponent.hasPrefix("Kernel-") else { throw StepFailure(step: "Restore", detail: "Choose a kernel installation backup") }
        let folder = URL(filePath: path)
        let snapshot = try JSONDecoder().decode(InstallSnapshot.self, from: Data(contentsOf: folder.appending(path: "snapshot.json")))
        var allowed = [SupportPaths.Steam.app.path]
        if let macSteam = r.macSteam { allowed += [URL(filePath: macSteam).appending(path: "dylib.version").path, URL(filePath: macSteam).appending(path: "signatures").path] }
        allowed += [SupportPaths.runners.path, SupportPaths.bridge.path, SupportPaths.toolList.path] + notProtonCoreTargets.map(\.path)
        for item in snapshot.items {
            let path = URL(filePath: item.original)
            if path.deletingLastPathComponent().standardizedFileURL.path == SupportPaths.Steam.compatTools.standardizedFileURL.path && path.lastPathComponent.hasPrefix("notproton") { allowed.append(item.original) }
        }
        guard snapshot.items.first?.original == allowed[0], Set(snapshot.items.map(\.original)).isSubset(of: Set(allowed)) else { throw StepFailure(step: "Restore", detail: "Backup does not match this installation") }
        let lock = try DeploymentContent.acquireInstallationLock(in: SupportPaths.applicationSupport, steamFolder: SupportPaths.Steam.app.deletingLastPathComponent()); defer { lock.release() }
        try snapshot.verifyRecovery(in: folder, interrupted: r.recoverInterrupted == true); try requireIdle()
        let recovery = URL(filePath: r.data).appending(path: "RuntimeBackups/Kernel-\(UUID().uuidString)")
        let current = try InstallSnapshot.capture(snapshot.items.map { URL(filePath: $0.original) }, in: recovery)
        do { try snapshot.restore(from: folder, beforeMutation: requireIdle) }
        catch { try requireIdle(); try current.restore(from: recovery, beforeMutation: requireIdle); throw error }
        try current.recordInstalled(in: recovery)
        try Data("restored\n".utf8).write(to: folder.appending(path: "status"), options: .atomic)
        register(SupportPaths.Steam.app); return recovery.path
    }
}
