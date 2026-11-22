import Foundation
import CryptoKit
import Darwin

/// Copies and verifies before switching configuration. The source remains a recovery copy.
public enum DirectoryMigration {
    public enum Selection: Sendable { case all, lua }
    public struct Result: Sendable { public let copied: Int; public let identical: Int }
    private struct Entry: Equatable { let relative: String; let digest: String }

    private static func digest(_ url: URL, copyingTo output: URL? = nil) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AppFailure("读取迁移文件失败 / Cannot read migration file：\(url.path) (\(errno))") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw AppFailure("迁移只支持普通文件 / Migration requires regular files") }
        var writer: FileHandle?
        if let output {
            let out = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw AppFailure("创建迁移副本失败 / Cannot create migration copy：\(output.path) (\(errno))") }
            writer = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        }
        defer { try? writer?.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes); try writer?.write(contentsOf: bytes)
        }
        try writer?.synchronize()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw AppFailure("迁移期间源文件发生变化 / Source changed during migration")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func entries(_ root: URL, selection: Selection) throws -> [Entry] {
        guard FileStore.fm.fileExists(atPath: root.path) else { return [] }
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AppFailure("迁移路径必须是目录 / Migration path must be a directory") }
        var error: Error?
        guard let walk = FileStore.fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], errorHandler: { _, e in error = e; return false }) else { throw AppFailure("无法扫描迁移目录 / Cannot scan migration folder") }
        var result: [Entry] = [], seen = Set<String>()
        for case let file as URL in walk {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw AppFailure("迁移目录包含符号链接 / Migration folder contains a symbolic link：\(file.lastPathComponent)") }
            if values.isDirectory == true { continue }
            if selection == .lua && file.pathExtension.lowercased() != "lua" { continue }
            guard values.isRegularFile == true else { throw AppFailure("迁移目录包含特殊文件 / Migration folder contains a special file") }
            let components = file.standardizedFileURL.pathComponents
            guard components.starts(with: root.pathComponents) else { throw AppFailure("迁移文件不在源目录内 / Migration file is outside the source folder") }
            let relative = components.dropFirst(root.pathComponents.count).joined(separator: "/")
            guard result.count < 100_000, seen.insert(relative.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppFailure("迁移文件过多或名称大小写冲突 / Too many files or case-insensitive filename conflict") }
            result.append(Entry(relative: relative, digest: try digest(file)))
        }
        if let error { throw error }
        return result.sorted { $0.relative < $1.relative }
    }
    @discardableResult public static func apply(from source: URL, to destination: URL, selection: Selection,
                                                lockRoot: URL, validate: () throws -> Void = {}, commit: () throws -> Void) throws -> Result {
        let sourceRequest = source, targetRequest = destination
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        func check() throws {
            guard sourceRequest.resolvingSymlinksInPath().standardizedFileURL == source, targetRequest.resolvingSymlinksInPath().standardizedFileURL == target else { throw AppFailure("迁移目录在操作期间改变 / Migration folder changed during the operation") }
            try validate()
        }
        if source == target { try validate(); try commit(); return Result(copied: 0, identical: 0) }
        guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/"), source.path != "/", target.path != "/" else {
            throw AppFailure("新旧迁移目录不能互相包含 / Migration folders must not contain each other")
        }
        try FileStore.mkdir(lockRoot)
        let fd = open(lockRoot.appendingPathComponent(".migration-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppFailure("无法锁定迁移操作 / Cannot lock migration") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("另一个目录迁移正在进行 / Another folder migration is running") }
        try check()
        let snapshot = try entries(source, selection: selection)
        var missing: [Entry] = [], identical = 0
        for item in snapshot {
            let dest = try GamePatches.target(item.relative, root: target)
            if FileStore.fm.fileExists(atPath: dest.path) {
                guard try digest(dest) == item.digest else { throw AppFailure("目标存在不同内容，未切换目录 / Conflicting destination; folder unchanged：\(item.relative)") }
                identical += 1
            } else { missing.append(item) }
        }
        var created: [Entry] = []
        do {
            for item in missing {
                try check(); try Task.checkCancellation()
                let original = try GamePatches.target(item.relative, root: source)
                let dest = try GamePatches.target(item.relative, root: target)
                try FileStore.mkdir(dest.deletingLastPathComponent())
                let stage = dest.deletingLastPathComponent().appendingPathComponent(".fluent-migrate-\(UUID().uuidString)")
                defer { try? FileStore.fm.removeItem(at: stage) }
                guard try digest(original, copyingTo: stage) == item.digest, try digest(stage) == item.digest else { throw AppFailure("迁移副本校验失败 / Migration copy verification failed") }
                // RENAME_EXCL never overwrites a file created after preflight.
                guard renamex_np(stage.path, dest.path, UInt32(RENAME_EXCL)) == 0 else { throw AppFailure("提交迁移副本失败 / Cannot commit migration copy：\(dest.path) (\(errno))") }
                created.append(item)
            }
            try check()
            guard try entries(source, selection: selection) == snapshot else { throw AppFailure("迁移期间源目录发生变化，未切换配置 / Source folder changed; configuration unchanged") }
            for item in snapshot {
                guard try digest(GamePatches.target(item.relative, root: target)) == item.digest else { throw AppFailure("迁移后目标校验失败 / Destination verification failed") }
            }
            try check(); try commit()
            return Result(copied: created.count, identical: identical)
        } catch {
            var retained = false
            for item in created.reversed() {
                do {
                    let file = try GamePatches.target(item.relative, root: target)
                    if !FileStore.fm.fileExists(atPath: file.path) { continue }
                    guard try digest(file) == item.digest else { retained = true; continue }
                    try FileStore.fm.removeItem(at: file)
                } catch { retained = true }
            }
            if retained { throw AppFailure("\(error.localizedDescription)；部分目标文件已变化，已保留供检查；源文件未删除 / Some destination files changed and were retained; source files were not deleted") }
            throw error
        }
    }
}

public enum PreferenceStore {
    @discardableResult public static func save(_ preferences: Preferences, defaults: AppPaths, migrateLua: Bool,
                                               steamRunning: () -> Bool = { SteamProcesses.isRunning }) throws -> DirectoryMigration.Result? {
        let oldData = FileStore.fm.fileExists(atPath: defaults.settings.path) ? try FileStore.read(defaults.settings) : nil
        let previous = try oldData.map { try JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        let source = previous.applying(to: defaults).lua, target = preferences.applying(to: defaults).lua
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(preferences)
        func commit() throws {
            try FileTransaction(backupRoot: defaults.backups).apply([(defaults.settings, bytes)], reason: "保存设置 / Save settings",
                expectations: [defaults.settings: oldData.map(FileStore.hash) ?? "missing"])
        }
        if migrateLua && source.resolvingSymlinksInPath() != target.resolvingSymlinksInPath() {
            return try DirectoryMigration.apply(from: source, to: target, selection: .lua, lockRoot: defaults.backups, validate: {
                guard !steamRunning() else { throw AppFailure("迁移 Lua 目录前请退出 Steam / Quit Steam before migrating the Lua folder") }
            }, commit: commit)
        }
        try commit(); return nil
    }
}
