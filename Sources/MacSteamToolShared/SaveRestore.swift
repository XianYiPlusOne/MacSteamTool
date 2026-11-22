import Foundation

public struct SaveRestoreResult: Sendable {
    public let files: Int
    public let previousBackup: URL?
}

extension Saves {
    /// Verify all files before the destination is touched. Unlisted files are rejected.
    public static func verifyBackup(_ directory: URL) throws -> [String: String] {
        guard !FileStore.fm.fileExists(atPath: directory.appendingPathComponent(".INCOMPLETE").path) else { throw AppFailure("此存档备份未完整完成，不能还原 / Save backup is incomplete and cannot be restored") }
        let sums = try FileStore.decode([String: String].self, at: directory.appendingPathComponent(".fluent-checksums.json"))
        guard sums.count <= 100_000 else { throw AppFailure("存档文件数量过多 / Too many save files") }
        for (relative, expected) in sums {
            guard validSaveRelativePath(relative), TextUtil.validKey(expected) else { throw AppFailure("存档备份校验目录包含无效路径或摘要 / Save backup checksum index contains an invalid path or hash") }
            let file = directory.appendingPathComponent(relative)
            let root = directory.resolvingSymlinksInPath().standardizedFileURL
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
                  try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink != true,
                  FileStore.hash(try FileStore.read(file)) == expected else { throw AppFailure("存档备份校验失败 / Save backup verification failed：\(relative)") }
        }
        var enumerationError: Error?
        guard let iterator = FileStore.fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw AppFailure("无法检查备份目录 / Cannot inspect the backup directory") }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AppFailure("存档备份包含符号链接 / Save backup contains a symbolic link") }
            if values.isRegularFile == true {
                let relative = String(file.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
                guard relative == ".fluent-checksums.json" || sums[relative] != nil else { throw AppFailure("备份包含未经校验的文件 / Backup contains an unverified file：\(relative)") }
            }
        }
        if let enumerationError { throw enumerationError }
        return sums
    }
    private static func validSaveRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) &&
        path != ".fluent-checksums.json" && path != ".INCOMPLETE"
    }
    public static func restore(_ backup: URL, to destination: URL, backupRoot: URL) throws -> SaveRestoreResult {
        let sums = try verifyBackup(backup)
        let source = backup.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let safeBackupRoot = backupRoot.resolvingSymlinksInPath().standardizedFileURL
        guard source != target, !source.path.hasPrefix(target.path + "/"), !target.path.hasPrefix(source.path + "/"),
              safeBackupRoot != target, !safeBackupRoot.path.hasPrefix(target.path + "/"),
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw AppFailure("备份、存档和回退目录必须相互独立，目标不能是符号链接 / Backup, save and rollback directories must be separate; target cannot be a symbolic link") }
        let parent = target.deletingLastPathComponent()
        try FileStore.mkdir(parent)
        let staging = parent.appendingPathComponent(".fluent-restore-\(UUID().uuidString)")
        let retired = parent.appendingPathComponent(".fluent-previous-\(UUID().uuidString)")
        try FileStore.mkdir(staging)
        defer { try? FileStore.fm.removeItem(at: staging) }
        for relative in sums.keys.sorted() {
            let data = try FileStore.read(source.appendingPathComponent(relative))
            guard FileStore.hash(data) == sums[relative] else { throw AppFailure("还原准备期间备份内容发生变化 / Backup content changed while preparing restoration") }
            try FileStore.write(data, to: staging.appendingPathComponent(relative))
        }
        var previous: URL?
        if FileStore.fm.fileExists(atPath: target.path) {
            let folder = safeBackupRoot.appendingPathComponent("before-restore-\(UUID().uuidString)")
            _ = try self.backup(target, to: folder)
            _ = try verifyBackup(folder)
            previous = folder
            try FileStore.fm.moveItem(at: target, to: retired)
        }
        do { try FileStore.fm.moveItem(at: staging, to: target) }
        catch {
            if previous != nil { try FileStore.fm.moveItem(at: retired, to: target) }
            throw error
        }
        // Original content remains in a verified backup even if retiring cleanup fails.
        if previous != nil { try? FileStore.fm.removeItem(at: retired) }
        return SaveRestoreResult(files: sums.count, previousBackup: previous)
    }
    public static func clear(_ destination: URL, backupRoot: URL) throws -> SaveRestoreResult {
        let empty = backupRoot.appendingPathComponent(".empty-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: empty) }
        try FileStore.json([String: String](), to: empty.appendingPathComponent(".fluent-checksums.json"))
        return try restore(empty, to: destination, backupRoot: backupRoot)
    }
}
