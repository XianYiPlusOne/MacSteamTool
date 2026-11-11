import Foundation

public struct OnlineFixResult: Codable, Identifiable, Sendable {
    public var title: String; public var url: String; public var version: String
    public var id: String { url }
}
public struct OnlineFixFile: Codable, Identifiable, Sendable {
    public var name: String; public var url: String; public var info: String; public var directory: String
    public var id: String { url }
}
public struct OnlineFixDetail: Codable, Sendable {
    public var title: String; public var url: String; public var instructions: String; public var files: [OnlineFixFile]
}
public struct PatchEntry: Identifiable, Sendable {
    public var id: String { relative }
    public let relative: String; public let data: Data; public let originalHash: String
    public var replacing: Bool { originalHash != "missing" }
}
public struct PatchRegistry: Sendable {
    public let url: URL; public let data: Data; public let originalHash: String
}
public struct PatchRegistryReceipt: Codable, Sendable {
    public let path: String; public let sha256: String
}
public struct PatchPlan: Identifiable, Sendable {
    public let id = UUID()
    public let appID: Int; public let gameRoot: URL; public let source: String; public let entries: [PatchEntry]
    public var registry: PatchRegistry? = nil
    public var windowsTarget: PatchWindowsTarget? = nil
}
public struct PatchReceipt: Codable, Identifiable, Sendable {
    public let id: String; public let appID: Int; public let gameRoot: String; public let source: String
    public let date: Date; public let backup: BackupRecord; public let deployed: [String: String]
    public var restored: Bool
    public var registry: PatchRegistryReceipt? = nil
    public var windowsTarget: PatchWindowsTarget? = nil
    public var executableSHA256: String? = nil
}
public enum GamePatches {
    public static func target(_ relative: String, root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !relative.contains("\\"), !relative.contains(":"), !relative.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(" ") && !$0.hasSuffix(".") }) else { throw AppFailure("补丁包含无效路径 / Patch contains an invalid path：\(relative)") }
        var current = root.resolvingSymlinksInPath().standardizedFileURL
        for part in parts {
            current.appendPathComponent(part)
            guard (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw AppFailure("补丁路径包含符号链接 / Patch path contains a symbolic link：\(relative)") }
        }
        return current
    }
    public static func plan(package: URL, gameRoot: URL, appID: Int) throws -> PatchPlan {
        guard UInt32(exactly: appID) != nil, appID > 0 else { throw AppFailure("无效 AppID / Invalid AppID") }
        let source = package.resolvingSymlinksInPath().standardizedFileURL, root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        guard (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true, source != root, !source.path.hasPrefix(root.path + "/"), !root.path.hasPrefix(source.path + "/") else { throw AppFailure("补丁目录与游戏目录必须独立 / Patch and game directories must be separate") }
        var enumerationError: Error?
        guard let walk = FileStore.fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw AppFailure("无法读取补丁目录 / Cannot read the patch directory") }
        var entries: [PatchEntry] = []; var seen = Set<String>(); var total = 0
        for case let file as URL in walk {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true else { throw AppFailure("补丁不能包含链接 / Patch cannot contain links") }
            if info.isDirectory == true { continue }
            guard info.isRegularFile == true else { throw AppFailure("补丁只能包含普通文件 / Patch may contain only regular files") }
            let components = file.standardizedFileURL.pathComponents
            guard components.starts(with: source.pathComponents) else { throw AppFailure("补丁文件位于源目录以外 / Patch file is outside the source directory") }
            let relative = components.dropFirst(source.pathComponents.count).joined(separator: "/")
            if relative == ".DS_Store" || relative.hasPrefix("__MACOSX/") { continue }
            let dest = try target(relative, root: root)
            guard seen.insert(relative.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppFailure("补丁文件名称冲突 / Patch filename conflict：\(relative)") }
            let data = try FileStore.read(file); total += data.count
            guard entries.count < 10000, total <= 512 * 1024 * 1024 else { throw AppFailure("补丁超过限制 / Patch exceeds 512 MiB or 10000 files") }
            let original = FileStore.fm.fileExists(atPath: dest.path) ? FileStore.hash(try FileStore.read(dest)) : "missing"
            entries.append(PatchEntry(relative: relative, data: data, originalHash: original))
        }
        if let enumerationError { throw enumerationError }
        guard !entries.isEmpty else { throw AppFailure("补丁目录没有文件 / Patch directory is empty") }
        return PatchPlan(appID: appID, gameRoot: root, source: source.lastPathComponent, entries: entries.sorted { $0.relative < $1.relative })
    }
    public static func onlinePlan(package: URL, gameRoot: URL, appID: Int, executable: URL, paths: AppPaths, bottle: URL? = nil, crossOverApp: URL? = nil) throws -> PatchPlan {
        let target = try PatchWindowsTarget.inspect(executable: executable, gameRoot: gameRoot, appID: appID, paths: paths, bottle: bottle, crossOverApp: crossOverApp)
        var result = try plan(package: package, gameRoot: gameRoot, appID: appID)
        try target.validateFiles(result.entries); result.windowsTarget = target; return result
    }
    public static func addingOverrides(to plan: PatchPlan, executable: URL, libraries: [String], paths: AppPaths) throws -> PatchPlan {
        let name = try WineOverrides.executable(executable, inside: plan.gameRoot)
        let prefix = plan.windowsTarget.map { URL(fileURLWithPath: $0.prefix) } ?? SteamLibrary.prefixes(paths).first(where: { $0.id == plan.appID })?.url
        guard let prefix else { throw AppFailure("该游戏没有 Windows 容器 / No Windows bottle exists for this game") }
        if let target = plan.windowsTarget { guard URL(fileURLWithPath: target.executable).lastPathComponent == name else { throw AppFailure("DLL 覆盖的程序与目标不一致 / Override executable differs from target") } }
        let url = prefix.appendingPathComponent("user.reg").standardizedFileURL
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw AppFailure("Wine 注册表不能是符号链接 / Wine registry cannot be a symbolic link") }
        let original = try FileStore.read(url)
        var result = plan
        result.registry = PatchRegistry(url: url, data: try WineOverrides.edit(original, executable: name, libraries: libraries), originalHash: FileStore.hash(original))
        return result
    }
    public static func install(_ plan: PatchPlan, paths: AppPaths) throws -> PatchReceipt {
        var changes: [(URL, Data?)] = []; var expected: [URL: String] = [:]; var deployed: [String: String] = [:]
        for entry in plan.entries {
            let file = try target(entry.relative, root: plan.gameRoot)
            changes.append((file, entry.data)); expected[file] = entry.originalHash; deployed[entry.relative] = FileStore.hash(entry.data)
        }
        if let registry = plan.registry { changes.append((registry.url, registry.data)); expected[registry.url] = registry.originalHash }
        if let target = plan.windowsTarget {
            _ = try target.launch(appID: plan.appID, command: target.executable, paths: paths)
            try target.validateFiles(plan.entries)
            expected[URL(fileURLWithPath: target.executable)] = target.executableHash
        }
        let journal = FileTransaction(backupRoot: paths.data.appendingPathComponent("PatchBackups"))
        let backup = try journal.apply(changes, reason: "游戏补丁 \(plan.appID) · \(plan.source)", expectations: expected)
        var receipt = PatchReceipt(id: plan.id.uuidString, appID: plan.appID, gameRoot: plan.gameRoot.path, source: plan.source, date: Date(), backup: backup, deployed: deployed, restored: false)
        receipt.windowsTarget = plan.windowsTarget
        if let target = plan.windowsTarget { receipt.executableSHA256 = deployed.first { key, _ in (try? Self.target(key, root: plan.gameRoot).path) == target.executable }?.value ?? target.executableHash }
        receipt.registry = plan.registry.map { PatchRegistryReceipt(path: $0.url.path, sha256: FileStore.hash($0.data)) }
        do { try FileStore.json(receipt, to: paths.data.appendingPathComponent("PatchRecords/\(receipt.id).json")) }
        catch { try journal.restore(backup, allowedRoots: [plan.gameRoot] + (plan.registry.map { [$0.url] } ?? [])); throw error }
        return receipt
    }
    public static func receipts(paths: AppPaths) -> [PatchReceipt] {
        FileStore.files(paths.data.appendingPathComponent("PatchRecords")).compactMap { try? FileStore.decode(PatchReceipt.self, at: $0) }.sorted { $0.date > $1.date }
    }
    public static func restore(_ receipt: PatchReceipt, paths: AppPaths) throws {
        guard !receipt.restored, UUID(uuidString: receipt.id) != nil else { throw AppFailure("补丁记录无效或已经还原 / Patch record is invalid or has already been restored") }
        let root = URL(fileURLWithPath: receipt.gameRoot); var expected: [URL: String] = [:]
        for (relative, hash) in receipt.deployed { expected[try target(relative, root: root)] = hash }
        var roots = [root]
        if let registry = receipt.registry {
            guard let prefix = receipt.windowsTarget.map({ URL(fileURLWithPath: $0.prefix) }) ?? SteamLibrary.prefixes(paths).first(where: { $0.id == receipt.appID })?.url,
                  prefix.appendingPathComponent("user.reg").standardizedFileURL.path == registry.path else { throw AppFailure("补丁备份中的 Wine 前缀与当前游戏不一致 / Backup Wine prefix does not match this game") }
            let file = URL(fileURLWithPath: registry.path); expected[file] = registry.sha256; roots.append(file)
        }
        guard Set(receipt.backup.files.map(\.original)) == Set(expected.keys.map(\.path)) else { throw AppFailure("补丁备份记录与部署清单不一致 / Patch backup records do not match the deployment manifest") }
        try FileTransaction(backupRoot: paths.data.appendingPathComponent("PatchBackups")).restore(receipt.backup, allowedRoots: roots, expectations: expected)
        var restored = receipt; restored.restored = true
        try FileStore.json(restored, to: paths.data.appendingPathComponent("PatchRecords/\(receipt.id).json"))
    }
}
