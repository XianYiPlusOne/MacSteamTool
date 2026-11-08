import Foundation
import CryptoKit

struct InstallRequest: Codable {
    let companion: String
    let steamApp: String
    let steamData: String
    let notProton: String
    let data: String
    var crossOver: String?
    var backup: String?
    var kernel: String?
    var source: String?
    var macSteam: String?
    var remove: Bool?
    var cleanRunners: Bool?
    var recoverInterrupted: Bool?
}
struct InstallSnapshot: Codable {
    struct Item: Codable { let original: String; let stored: String; let existed: Bool; let sha256: String }
    let items: [Item]
    // Hash file content, names and link targets; never follow links outside a tree.
    static func digest(_ root: URL) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) || (try? fm.destinationOfSymbolicLink(atPath: root.path)) != nil else { return "missing" }
        var hash = SHA256()
        func visit(_ url: URL, relative: String) throws {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            hash.update(data: Data((relative + "\0" + (type?.rawValue ?? "") + "\0").utf8))
            if type == .typeSymbolicLink { hash.update(data: Data(try fm.destinationOfSymbolicLink(atPath: url.path).utf8)) }
            else if type == .typeDirectory {
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() { try visit(url.appending(path: name), relative: relative + "/" + name) }
            } else if type == .typeRegular {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1048576), !data.isEmpty { hash.update(data: data) }
            } else { throw StepFailure(step: "Backup", detail: "Unsupported installation file: \(relative)") }
            hash.update(data: Data([0]))
        }
        try visit(root, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func recordInstalled(in folder: URL) throws {
        let hashes = try items.map { try Self.digest(URL(filePath: $0.original)) }
        try JSONEncoder().encode(hashes).write(to: folder.appending(path: "installed.json"), options: .atomic)
        try Self.mark("complete", in: folder)
    }
    static func mark(_ status: String, in folder: URL) throws {
        try Data((status + "\n").utf8).write(to: folder.appending(path: "status"), options: .atomic)
    }
    func verifyRecovery(in folder: URL, interrupted: Bool) throws {
        let status = (try? String(contentsOf: folder.appending(path: "status"), encoding: .utf8)) ?? ""
        if interrupted {
            guard status == "incomplete\n" || status == "recovery-needed\n" else { throw StepFailure(step: "Restore", detail: "This backup is not an interrupted installation") }
            // Partial deployments have no reliable post-install hash. Their current state
            // must be captured into a second complete backup before any restoration.
            try verifyBackup(in: folder)
        } else { try verifyInstalled(in: folder) }
    }
    func verifyBackup(in folder: URL) throws {
        for item in items {
            guard item.stored.allSatisfy(\.isNumber), !item.stored.isEmpty,
                  try Self.digest(folder.appending(path: item.stored)) == item.sha256 else { throw StepFailure(step: "Rollback", detail: "Backup integrity check failed") }
        }
    }
    func verifyInstalled(in folder: URL) throws {
        let hashes = try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appending(path: "installed.json")))
        guard hashes.count == items.count else { throw StepFailure(step: "Restore", detail: "Invalid installation receipt") }
        for (item, expected) in zip(items, hashes) {
            guard try Self.digest(URL(filePath: item.original)) == expected else { throw StepFailure(step: "Restore", detail: "Files changed after this installation: \(item.original). Restore refused.") }
        }
    }
    static func capture(_ urls: [URL], in folder: URL) throws -> Self {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var items: [Item] = []
        for (index, url) in urls.enumerated() {
            guard !folder.path.hasPrefix(url.path + "/"), folder != url else { throw StepFailure(step: "Backup", detail: "Backup must be outside installation roots") }
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw StepFailure(step: "Backup", detail: "An installation root is a symbolic link") }
            let exists = fm.fileExists(atPath: url.path), name = String(index)
            if exists { try copy(url, to: folder.appending(path: name)) }
            items.append(Item(original: url.path, stored: name, existed: exists, sha256: try digest(folder.appending(path: name))))
        }
        let snapshot = Self(items: items)
        try JSONEncoder().encode(snapshot).write(to: folder.appending(path: "snapshot.json"), options: .atomic)
        try mark("incomplete", in: folder)
        return snapshot
    }
    static func copy(_ from: URL, to: URL) throws {
        // APFS clone keeps a full rollback copy without copying gigabytes of unchanged runner data.
        let process = Process(); process.executableURL = URL(filePath: "/bin/cp"); process.arguments = ["-cRp", from.path, to.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: from, to: to)
        }
    }
    func restore(from folder: URL, beforeMutation: () throws -> Void = {}) throws {
        let fm = FileManager.default
        // Validate every saved tree before mutating any original.
        try verifyBackup(in: folder)
        for item in items.reversed() {
            let original = URL(filePath: item.original), parent = original.deletingLastPathComponent()
            guard !item.stored.contains("/"), original.path.hasPrefix("/"), (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw StepFailure(step: "Rollback", detail: "Invalid backup path") }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let stage = parent.appending(path: ".fluent-restore-\(UUID().uuidString)")
            let prior = parent.appending(path: ".fluent-prior-\(UUID().uuidString)")
            if item.existed { try Self.copy(folder.appending(path: item.stored), to: stage) }
            defer { try? fm.removeItem(at: stage) }
            try beforeMutation()
            let exists = fm.fileExists(atPath: original.path)
            if exists { try fm.moveItem(at: original, to: prior) }
            do { if item.existed { try fm.moveItem(at: stage, to: original) } }
            catch { if exists { try fm.moveItem(at: prior, to: original) }; throw error }
            if exists { try fm.removeItem(at: prior) }
        }
    }
}

enum InstallSession {
    static func companion(_ path: String) throws {
        let app = URL(filePath: path)
        guard path.hasPrefix("/"), let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.notproton.NotProton" else { throw StepFailure(step: "Validate companion", detail: "Choose the official NotProton application") }
        let resources = app.appending(path: "Contents/Resources/NotProtonApp_NotProtonApp.bundle")
        setenv("FLUENT_NOTPROTON_APP", app.path, 1)
        setenv("FLUENT_NOTPROTON_RESOURCES", resources.path, 1)
        setenv("FLUENT_NOTPROTON_VERSION", (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"), 1)
    }
    static func roots() -> [URL] {
        [SupportPaths.Steam.app, SupportPaths.support, SupportPaths.Steam.compatTools, SupportPaths.Steam.legacyCompat, SteamModifications.shared.file]
    }
    static func requireIdle() throws {
        guard !SteamBundle.isRunning else { throw StepFailure(step: "Close Steam", detail: "Quit Steam before changing runtimes; this helper never stops Steam or games") }
        for build in RunnerStore.clonedBuilds() where RunnerInstaller.isRunning(from: SupportPaths.clonedRoot(forBuild: build)) { throw StepFailure(step: "Close games", detail: "A NotProton runner is active") }
    }
    static func configure(_ r: InstallRequest) throws {
        for path in [r.steamApp, r.steamData, r.notProton, r.data] {
            guard path.hasPrefix("/"), !path.contains("\n"), path != "/", URL(filePath: path).standardizedFileURL.path == path else { throw StepFailure(step: "Validate paths", detail: "Absolute normalized installation paths required") }
        }
        guard r.steamApp.hasSuffix(".app") else { throw StepFailure(step: "Validate paths", detail: "A Steam.app bundle is required") }
        setenv("FLUENT_STEAM_APP", r.steamApp, 1); setenv("FLUENT_STEAM_DATA", r.steamData, 1)
        setenv("FLUENT_NOTPROTON_SUPPORT", r.notProton, 1); setenv("FLUENT_NOTPROTON_DOWNLOADS", URL(filePath: r.data).appending(path: "Cache/ValvePackages").path, 1)
    }
    static func restore(_ r: InstallRequest) throws -> String {
        try configure(r); try requireIdle()
        guard let path = r.backup, URL(filePath: path).deletingLastPathComponent().standardizedFileURL.path == URL(filePath: r.data).appending(path: "RuntimeBackups").standardizedFileURL.path, URL(filePath: path).lastPathComponent.hasPrefix("NotProton-") else { throw StepFailure(step: "Restore", detail: "Choose a NotProton installation backup") }
        let folder = URL(filePath: path)
        let snapshot = try JSONDecoder().decode(InstallSnapshot.self, from: Data(contentsOf: folder.appending(path: "snapshot.json")))
        guard snapshot.items.map(\.original) == roots().map(\.path) else { throw StepFailure(step: "Restore", detail: "Backup paths do not match this Steam installation") }
        let lock = try DeploymentContent.acquireInstallationLock(in: SupportPaths.applicationSupport, steamFolder: SupportPaths.Steam.app.deletingLastPathComponent()); defer { lock.release() }
        try snapshot.verifyRecovery(in: folder, interrupted: r.recoverInterrupted == true)
        try requireIdle()
        // Retain the state being replaced as well, so a failed recovery remains repairable.
        let recovery = URL(filePath: r.data).appending(path: "RuntimeBackups/NotProton-\(UUID().uuidString)")
        let current = try InstallSnapshot.capture(roots(), in: recovery)
        do { try snapshot.restore(from: folder, beforeMutation: requireIdle); SteamBundle.register(SupportPaths.Steam.app) }
        catch { try requireIdle(); try current.restore(from: recovery, beforeMutation: requireIdle); throw error }
        try current.recordInstalled(in: recovery)
        try Data("restored\n".utf8).write(to: folder.appending(path: "status"), options: .atomic)
        return recovery.path
    }
    static func install(_ r: InstallRequest, progress: @escaping @Sendable (String) -> Void) async throws -> String {
        try companion(r.companion)
        try configure(r); try requireIdle()
        guard SteamBundle.readInfoPlist(at: SupportPaths.Steam.infoPlist)?["CFBundleIdentifier"] as? String == "com.valvesoftware.steam" else { throw StepFailure(step: "Validate Steam", detail: "Target is not Steam.app") }
        let payload = try InstallPayload.locate(); let bridge = try BridgePayload.locate()
        for build in RunnerStore.clonedBuilds() where RunnerInstaller.isRunning(from: SupportPaths.clonedRoot(forBuild: build)) { throw StepFailure(step: "Close games", detail: "A NotProton runner is active") }
        let lock = try DeploymentContent.acquireInstallationLock(in: SupportPaths.applicationSupport, steamFolder: SupportPaths.Steam.app.deletingLastPathComponent()); defer { lock.release() }
        let backup = URL(filePath: r.data).appending(path: "RuntimeBackups/NotProton-\(UUID().uuidString)")
        progress("Backing up Steam and NotProton")
        let snapshot = try InstallSnapshot.capture(roots(), in: backup)
        do {
            try requireIdle()
            let outcome = try SteamInstaller.run(payload: payload, bridgePayload: bridge, holdingInstallationLock: true, stopClient: { _, _ in
                guard !SteamBundle.isRunning else { throw StepFailure(step: "Install", detail: "Steam started during installation") }; return false
            }, resetInputAccess: {}, report: { progress($0.label) })
            if let source = r.crossOver, !source.isEmpty {
                let install = CrossOverSource.inspect(bundle: URL(filePath: source), isManual: true)
                _ = try RunnerSetup.run(from: install) { progress($0.label) }
            }
            let pinned = try DeploymentContent.pinnedFiles(bridge: SupportPaths.bridge, runners: SupportPaths.runners)
            if pinned.contains(where: { Digest.sha256IfPresent($0.destination) != $0.hash }) { _ = try await ValveFetcher.run { progress($0.label) } }
            try requireIdle()
            try SteamInstaller.finish(outcome)
            try snapshot.recordInstalled(in: backup)
            try Data("complete\n".utf8).write(to: backup.appending(path: "status"), options: .atomic)
            return backup.path
        } catch {
            try? InstallSnapshot.mark("recovery-needed", in: backup)
            do { try requireIdle() }
            catch { throw StepFailure(step: "Recovery needed", detail: "Steam or a runner started during installation. Close it before restoring backup: \(backup.path)") }
            progress("Restoring installation backup")
            do { try snapshot.restore(from: backup, beforeMutation: requireIdle); SteamBundle.register(SupportPaths.Steam.app); try InstallSnapshot.mark("restored", in: backup) }
            catch let rollback { throw StepFailure(step: "Rollback", detail: "Installation failed and rollback needs repair: \(rollback.localizedDescription). Backup: \(backup.path)") }
            throw error
        }
    }
}
