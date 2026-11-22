import Foundation
import CryptoKit
import ZIPFoundation
import Darwin

/// Journals every affected file before mutating it. Failure restores the whole batch.
public final class FileTransaction {
    public let backupRoot: URL
    public init(backupRoot: URL) { self.backupRoot = backupRoot }
    @discardableResult public func apply(_ changes: [(URL, Data?)], reason: String, expectations: [URL: String] = [:], libraryAppIDs: [Int]? = nil, validate: () throws -> Void = {}) throws -> BackupRecord {
        try FileStore.mkdir(backupRoot)
        let fd = open(backupRoot.appendingPathComponent(".write-lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppFailure("无法锁定备份目录 / Cannot lock the backup directory") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("另一个操作正在修改配置，请稍后再试 / Another operation is modifying the configuration; retry later") }
        for (url, expected) in expectations {
            let actual = FileStore.fm.fileExists(atPath: url.path) ? FileStore.hash(try FileStore.read(url)) : "missing"
            guard actual == expected else { throw AppFailure("文件已由其他程序修改 / File was changed by another application：\(url.lastPathComponent)。请刷新后重试 / Refresh and retry") }
        }
        try validate()
        let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + String(UUID().uuidString.prefix(8))
        let folder = backupRoot.appendingPathComponent(id)
        try FileStore.mkdir(folder)
        var record = BackupRecord(id: id, date: Date(), reason: reason, files: [], libraryAppIDs: libraryAppIDs)
        var unique: [URL: Data?] = [:]
        for (url, data) in changes { unique.updateValue(data, forKey: url.standardizedFileURL) }
        let ordered = unique.keys.sorted { $0.path < $1.path }
        for (i, url) in ordered.enumerated() {
            let exists = FileStore.fm.fileExists(atPath: url.path)
            let old = exists ? try FileStore.read(url) : Data()
            let stored = "\(i).bak"
            if exists { try FileStore.write(old, to: folder.appendingPathComponent(stored)) }
            record.files.append(BackupFile(original: url.path, stored: stored, sha256: FileStore.hash(old), existed: exists))
        }
        try FileStore.json(record, to: folder.appendingPathComponent("record.json"))
        try validate()
        do {
            for url in ordered {
                if let data = unique[url] ?? nil { try FileStore.write(data, to: url) }
                else if FileStore.fm.fileExists(atPath: url.path) { try FileStore.fm.removeItem(at: url) }
            }
        } catch {
            do { try restoreUnchecked(record) }
            catch let rollback { throw AppFailure("写入失败且回滚失败 / Write and rollback both failed：\(rollback.localizedDescription)。备份：\(folder.path)") }
            throw error
        }
        return record
    }
    private func restoreUnchecked(_ record: BackupRecord) throws {
        let folder = backupRoot.appendingPathComponent(record.id)
        for file in record.files {
            let original = URL(fileURLWithPath: file.original)
            if file.existed { try FileStore.write(FileStore.read(folder.appendingPathComponent(file.stored)), to: original) }
            else if FileStore.fm.fileExists(atPath: original.path) { try FileStore.fm.removeItem(at: original) }
        }
    }
    public func records() -> [BackupRecord] {
        FileStore.files(backupRoot).compactMap { try? FileStore.decode(BackupRecord.self, at: $0.appendingPathComponent("record.json")) }.sorted { $0.date > $1.date }
    }
    public func restore(_ record: BackupRecord, allowedRoots: [URL], expectations: [URL: String] = [:]) throws {
        guard record.libraryAppIDs == nil else { throw AppFailure("请使用游戏配置恢复，以保留其他游戏 / Use library restore to preserve other games") }
        let changes = try verifiedChanges(record, allowedRoots: allowedRoots)
        try apply(changes, reason: "还原 \(record.reason)", expectations: expectations)
    }
    func verifiedChanges(_ record: BackupRecord, allowedRoots: [URL]) throws -> [(URL, Data?)] {
        var changes: [(URL, Data?)] = []
        for file in record.files {
            let url = URL(fileURLWithPath: file.original).standardizedFileURL
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard allowedRoots.contains(where: { let root = $0.resolvingSymlinksInPath().standardizedFileURL; return resolved.path.hasPrefix(root.path + "/") || resolved == root }),
                  !file.stored.contains("/"), !record.id.contains("/") else { throw AppFailure("备份包含当前配置范围外的路径 / Backup contains paths outside the current configuration scope") }
            let data = file.existed ? try FileStore.read(backupRoot.appendingPathComponent(record.id).appendingPathComponent(file.stored)) : nil
            guard FileStore.hash(data ?? Data()) == file.sha256 else { throw AppFailure("备份校验失败 / Backup verification failed；未还原任何文件 / No files were restored") }
            changes.append((url, data))
        }
        return changes
    }
}

public struct ImportFile: Sendable {
    public var name: String; public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}
public enum ArchiveIO {
    public static let archiveExtensions: Set<String> = ["zip", "tar", "7z", "rar"]
    public static func readImport(_ urls: [URL]) async throws -> [ImportFile] {
        try importFiles(urls)
    }
    private static func deduplicate(_ files: [ImportFile]) throws -> [ImportFile] {
        guard !files.isEmpty else { throw AppFailure("没有可导入的 Lua、manifest 或 bin 文件 / No importable Lua, manifest or bin files") }
        var seen: [String: ImportFile] = [:]
        for file in files {
            let identity = file.name.precomposedStringWithCanonicalMapping.lowercased()
            if let old = seen[identity], old.data != file.data { throw AppFailure("导入中存在同名不同内容文件 / Import contains files with the same name but different contents：\(file.name)") }
            seen[identity] = file
        }
        return seen.values.sorted { $0.name < $1.name }
    }
    public static func importFiles(_ urls: [URL]) throws -> [ImportFile] {
        var files: [ImportFile] = []; var total = 0
        func append(_ name: String, _ data: Data) throws {
            total += data.count
            guard data.count <= 64 * 1024 * 1024, total <= 256 * 1024 * 1024, files.count < 4096 else { throw AppFailure("导入超过限制 / Import exceeds 64 MB per file, 256 MB or 4096 files") }
            let original = URL(fileURLWithPath: name)
            let base = original.deletingPathExtension().lastPathComponent + "." + original.pathExtension.lowercased()
            guard ["lua", "manifest", "bin"].contains(URL(fileURLWithPath: base).pathExtension.lowercased()) else { return }
            files.append(ImportFile(name: base, data: data))
        }
        for url in urls {
            try Task.checkCancellation()
            if archiveExtensions.contains(url.pathExtension.lowercased()) {
                try NativeArchive.read(url, library: true, visit: append)
            } else { try append(url.lastPathComponent, FileStore.read(url)) }
        }
        return try deduplicate(files)
    }
    public static func export(_ files: [ImportFile], to url: URL) throws {
        guard !FileStore.fm.fileExists(atPath: url.path) else { throw AppFailure("目标文件已存在，请选择新名称 / Destination exists; choose a new name") }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileStore.fm.removeItem(at: temp) }
        let archive = try Archive(url: temp, accessMode: .create)
        for file in files {
            try archive.addEntry(with: file.name, type: .file, uncompressedSize: Int64(file.data.count), compressionMethod: .deflate) { position, count in
                file.data.subdata(in: Int(position)..<(Int(position) + count))
            }
        }
        try FileStore.fm.moveItem(at: temp, to: url)
    }
}
