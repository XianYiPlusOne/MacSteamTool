import Foundation
import Darwin

public struct CloudRemoteFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let modifiedTime: UInt64
    public var sha256: String?
    enum CodingKeys: String, CodingKey { case path, size, sha256; case modifiedTime = "modified_time" }
}
private struct RemoteFileList: Decodable { let success: Bool; let complete: Bool; let files: [CloudRemoteFile] }
public struct CloudDeleteSource: Codable, Equatable, Sendable {
    public let provider: String
    public let tokenPath: String
    public let credentialHash: String
    public let configHash: String
}
public struct CloudLocalFile: Codable, Equatable, Sendable { public let size: Int; public let sha256: String }
public struct CloudLocalSnapshot: Codable, Equatable, Sendable {
    public let files: [String: CloudLocalFile]
    public let directories: [String]
    public var bytes: Int64 { files.values.reduce(0) { $0 + Int64($1.size) } }
}
public struct CloudDeleteTarget: Codable, Equatable, Identifiable, Sendable {
    public let kind: String
    public let path: String
    public let snapshot: CloudLocalSnapshot
    public var id: String { path }
}
public struct CloudDeletePreview: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let app: Int
    public let account: String
    public let source: CloudDeleteSource
    public let context: String
    public let local: [CloudDeleteTarget]
    public let remote: [CloudRemoteFile]
    public let directory: URL
    public var fileCount: Int { remote.count + local.reduce(0) { $0 + $1.snapshot.files.count } }
    public var totalBytes: Int64 { Int64(remote.reduce(UInt64(0)) { $0 + $1.size }) + local.reduce(0) { $0 + $1.snapshot.bytes } }
}
public struct CloudGameBackup: Codable, Sendable {
    public let preview: CloudDeletePreview
    public let remoteReceiptHash: String?
    public let manifestHash: String
}
private struct CloudDeletionBackupRecord: Codable {
    let preview: CloudDeletePreview
    let remoteReceiptHash: String?
}
private struct NativeBackupResult: Decodable { let success: Bool; let receiptHash: String; let files: Int }
private struct NativeDeleteResult: Decodable { let success: Bool; let deleted: Int; let remaining: Int }
private struct NativeReceipt: Decodable { let provider: String; let account: String; let app: String; let files: [CloudRemoteFile] }

public struct CloudGameDeletion: Sendable {
    public let paths: AppPaths
    private let execute: @Sendable ([String]) async throws -> String
    private let steamRunning: @Sendable () -> Bool
    public init(paths: AppPaths, engine: URL, steamRunning: @escaping @Sendable () -> Bool = { SteamProcesses.isRunning }, execute: (@Sendable ([String]) async throws -> String)? = nil) {
        self.paths = paths; self.steamRunning = steamRunning
        self.execute = execute ?? { try await CloudEngine.run($0, executable: engine, paths: paths, timeout: 900) }
    }
    public static func backupRoot(_ paths: AppPaths) -> URL { paths.data.appendingPathComponent("CloudDeleteBackups") }
    private func stopped() throws { guard !steamRunning() else { throw AppFailure("请先退出游戏和 Steam / Quit the game and Steam first") } }
    private func hashFile(_ file: URL) throws -> String { FileStore.fm.fileExists(atPath: file.path) ? try FileStore.hash(FileStore.read(file)) : "missing" }
    private func source(_ provider: CloudProvider) throws -> CloudDeleteSource {
        let config = try CloudConfiguration.load(paths: paths)
        guard config.provider == provider else { throw AppFailure("服务商设置尚未保存或已经改变，请保存后重新预览 / Save the selected provider, then preview again") }
        let token = try CloudEngine.effectiveCredentialsURL(provider, paths: paths).standardizedFileURL
        return try CloudDeleteSource(provider: provider.rawValue, tokenPath: token.path, credentialHash: [.local, .folder].contains(provider) ? "not-used" : hashFile(token), configHash: hashFile(paths.data.appendingPathComponent("CloudRedirect/config.json")))
    }
    private var context: String { [paths.data, paths.steam].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.joined(separator: "\n") }
    private func candidates(provider: CloudProvider, account: String, app: Int) throws -> [(String, URL)] {
        let data = paths.data.resolvingSymlinksInPath(), steam = paths.steam.resolvingSymlinksInPath()
        let suffix = "\(account)/\(app)"
        var list = [("cache", data.appendingPathComponent("CloudRedirect/storage/" + suffix)), ("legacy", data.appendingPathComponent("CloudRedirect/blobs/" + suffix)), ("userdata", steam.appendingPathComponent("userdata/" + suffix))]
        if provider == .folder {
            let config = try CloudConfiguration.load(paths: paths)
            guard config.folder.hasPrefix("/") else { throw AppFailure("云文件夹路径无效 / Invalid cloud folder") }
            let folder = URL(fileURLWithPath: config.folder).resolvingSymlinksInPath().standardizedFileURL
            for excluded in [steam, data.appendingPathComponent("CloudRedirect"), Self.backupRoot(paths).resolvingSymlinksInPath()] {
                guard folder != excluded, !folder.path.hasPrefix(excluded.path + "/"), !excluded.path.hasPrefix(folder.path + "/") else { throw AppFailure("云文件夹与受保护目录重叠 / Cloud folder overlaps a protected directory") }
            }
            list.insert(("sync", folder.appendingPathComponent(suffix)), at: 0)
        }
        return list
    }
    private static func noLinks(_ file: URL) throws {
        var current = file.standardizedFileURL
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                let systemAlias = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"][current.path]
                var trustedAlias = false
                if let expected = systemAlias, let resolved = realpath(current.path, nil) {
                    trustedAlias = String(cString: resolved) == expected; free(resolved)
                }
                guard info.st_mode & S_IFMT != S_IFLNK || trustedAlias else { throw AppFailure("存档或备份路径包含符号链接 / A save or backup path contains a symbolic link: \(current.path)") }
            }
            else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            current.deleteLastPathComponent()
        }
    }
    public static func snapshot(_ directory: URL) throws -> CloudLocalSnapshot {
        try noLinks(directory)
        let root = directory.standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AppFailure("目标不是存档目录 / Target is not a save directory") }
        var error: Error?, files: [String: CloudLocalFile] = [:], directories: [String] = [], total = 0
        guard let iterator = FileStore.fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, e in error = e; return false }) else { throw AppFailure("无法完整枚举存档 / Cannot fully enumerate saves") }
        for case let file as URL in iterator {
            guard files.count + directories.count < 20000 else { throw AppFailure("存档条目超过 20000 项 / Save exceeds 20000 entries") }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, file.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw AppFailure("存档包含链接或越界路径 / Save contains a link or an escaping path") }
            let relative = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if values.isDirectory == true { directories.append(relative) }
            else {
                guard values.isRegularFile == true else { throw AppFailure("存档包含特殊文件 / Save contains a special file") }
                let bytes = try FileStore.read(file); total += bytes.count
                guard files.count < 10000, total <= 2 * 1024 * 1024 * 1024 else { throw AppFailure("存档超出 10000 文件或 2 GiB 限制 / Save exceeds 10000 files or 2 GiB") }
                files[relative] = CloudLocalFile(size: bytes.count, sha256: FileStore.hash(bytes))
            }
        }
        if let error { throw error }
        return CloudLocalSnapshot(files: files, directories: directories.sorted())
    }
    private func localTargets(provider: CloudProvider, account: String, app: Int) throws -> [CloudDeleteTarget] {
        try candidates(provider: provider, account: account, app: app).compactMap { kind, path in
            try Self.noLinks(path)
            guard FileStore.fm.fileExists(atPath: path.path) else { return nil }
            return try CloudDeleteTarget(kind: kind, path: path.path, snapshot: Self.snapshot(path))
        }
    }
    private func remoteFiles(provider: CloudProvider, account: String, app: Int) async throws -> [CloudRemoteFile] {
        if [.local, .folder].contains(provider) { return [] }
        let result = try CloudOnline.decodeLast(RemoteFileList.self, from: await execute(["list-remote-app-files", provider.rawValue, account, String(app)]))
        guard result.success, result.complete, result.files.count <= 10000 else { throw AppFailure("云端列表不完整，不能备份或删除 / Incomplete remote listing; cannot back up or delete") }
        let prefix = "\(account)/\(app)/"; var seen = Set<String>(), total: UInt64 = 0
        for file in result.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard file.path.hasPrefix(prefix), file.path.utf8.count <= 4096, !file.path.contains("\\"), !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), seen.insert(file.path).inserted, file.size <= 256 * 1024 * 1024 else { throw AppFailure("云端对象路径、大小或重复项无效 / Invalid remote object path, size or duplicate") }
            total += file.size; guard total <= 2 * 1024 * 1024 * 1024 else { throw AppFailure("云端对象超出 2 GiB 备份限制 / Remote snapshot exceeds 2 GiB") }
        }
        return result.files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }
    public func preview(provider: CloudProvider, account: String, app: Int) async throws -> CloudDeletePreview {
        try stopped(); guard TextUtil.validID(String(app)) != nil else { throw AppFailure("无效 AppID / Invalid AppID") }
        let account = try CloudOnline.accountID(account), original = try source(provider), id = UUID()
        let local = try localTargets(provider: provider, account: account, app: app)
        let remote = try await remoteFiles(provider: provider, account: account, app: app)
        try stopped(); guard try source(provider) == original else { throw AppFailure("预览期间服务商配置变化，请重试 / Provider changed during preview") }
        return CloudDeletePreview(id: id, app: app, account: account, source: original, context: context, local: local, remote: remote, directory: Self.backupRoot(paths).appendingPathComponent("\(app)-\(id.uuidString)"))
    }
    private func validate(_ preview: CloudDeletePreview) throws -> CloudProvider {
        try stopped()
        guard let provider = CloudProvider(rawValue: preview.source.provider), preview.context == context, preview.account == (try CloudOnline.accountID(preview.account)), TextUtil.validID(String(preview.app)) != nil,
              try source(provider) == preview.source,
              preview.directory.standardizedFileURL.path == Self.backupRoot(paths).appendingPathComponent("\(preview.app)-\(preview.id.uuidString)").standardizedFileURL.path else { throw AppFailure("账号、服务商、路径或凭证已变化，请重新预览 / Account, provider, paths or credentials changed; preview again") }
        return provider
    }
    private func validateLocal(_ preview: CloudDeletePreview, provider: CloudProvider) throws {
        guard try localTargets(provider: provider, account: preview.account, app: preview.app) == preview.local else { throw AppFailure("本地存档或缓存已变化，请重新预览 / Local saves or caches changed; preview again") }
    }
    public func backup(_ preview: CloudDeletePreview) async throws -> CloudGameBackup {
        let provider = try validate(preview); try validateLocal(preview, provider: provider)
        guard preview.fileCount > 0 || !preview.local.isEmpty, !FileStore.fm.fileExists(atPath: preview.directory.path) else { throw AppFailure("无可备份目标或备份已存在，请重新预览 / No targets or backup already exists; preview again") }
        try Self.noLinks(preview.directory)
        try FileStore.fm.createDirectory(at: preview.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileStore.write(Data("Backup not yet verified".utf8), to: preview.directory.appendingPathComponent(".INCOMPLETE"))
        do {
            for (index, target) in preview.local.enumerated() {
                try stopped()
                let output = preview.directory.appendingPathComponent("local-\(index)/data")
                try FileStore.mkdir(output)
                for relative in target.snapshot.directories { try FileStore.mkdir(output.appendingPathComponent(relative)) }
                for (relative, file) in target.snapshot.files {
                    let bytes = try FileStore.read(URL(fileURLWithPath: target.path).appendingPathComponent(relative))
                    guard bytes.count == file.size, FileStore.hash(bytes) == file.sha256 else { throw AppFailure("备份期间存档变化 / Save changed during backup") }
                    let destination = output.appendingPathComponent(relative)
                    try FileStore.mkdir(destination.deletingLastPathComponent())
                    try FileStore.fm.copyItem(at: URL(fileURLWithPath: target.path).appendingPathComponent(relative), to: destination)
                }
                guard try Self.snapshot(output) == target.snapshot else { throw AppFailure("本地备份回读校验失败 / Local backup readback failed") }
            }
            var remoteHash: String?
            if ![.local, .folder].contains(provider) {
                struct NativePlan: Encodable { let provider: String; let account: String; let app: String; let tokenPath: String; let credentialHash: String; let configHash: String; let files: [CloudRemoteFile] }
                let plan = NativePlan(provider: provider.rawValue, account: preview.account, app: String(preview.app), tokenPath: preview.source.tokenPath, credentialHash: preview.source.credentialHash, configHash: preview.source.configHash, files: preview.remote)
                let request = preview.directory.appendingPathComponent("remote-plan.json")
                try FileStore.json(plan, to: request)
                let output = try await execute(["backup-app-checked", provider.rawValue, preview.account, String(preview.app), request.path, preview.directory.appendingPathComponent("remote").path])
                let result = try CloudOnline.decodeLast(NativeBackupResult.self, from: output)
                guard result.success, result.files == preview.remote.count, result.receiptHash == (try hashFile(preview.directory.appendingPathComponent("remote/receipt.json"))) else { throw AppFailure("云端备份未完整校验 / Remote backup not fully verified") }
                remoteHash = result.receiptHash
            }
            _ = try validate(preview); try validateLocal(preview, provider: provider)
            let record = CloudDeletionBackupRecord(preview: preview, remoteReceiptHash: remoteHash)
            let manifest = preview.directory.appendingPathComponent("backup.json"); try FileStore.json(record, to: manifest)
            let result = try CloudGameBackup(preview: preview, remoteReceiptHash: remoteHash, manifestHash: hashFile(manifest))
            try FileStore.fm.removeItem(at: preview.directory.appendingPathComponent(".INCOMPLETE"))
            try verifyBackup(result)
            return result
        } catch {
            try? FileStore.write(Data(error.localizedDescription.utf8), to: preview.directory.appendingPathComponent(".INCOMPLETE"))
            throw AppFailure("备份未完成，未删除任何源数据。保留副本：\(preview.directory.path)\n\(error.localizedDescription) / Backup incomplete; no source was deleted")
        }
    }
    public func verifyBackup(_ backup: CloudGameBackup) throws {
        let preview = backup.preview; _ = try validate(preview); try Self.noLinks(preview.directory)
        guard !FileStore.fm.fileExists(atPath: preview.directory.appendingPathComponent(".INCOMPLETE").path), try hashFile(preview.directory.appendingPathComponent("backup.json")) == backup.manifestHash else { throw AppFailure("备份未完成或记录被改动 / Incomplete or modified backup") }
        let record = try FileStore.decode(CloudDeletionBackupRecord.self, at: preview.directory.appendingPathComponent("backup.json"))
        guard record.preview == preview, record.remoteReceiptHash == backup.remoteReceiptHash else { throw AppFailure("备份范围不匹配 / Backup scope mismatch") }
        for (index, target) in preview.local.enumerated() {
            guard try Self.snapshot(preview.directory.appendingPathComponent("local-\(index)/data")) == target.snapshot else { throw AppFailure("本地备份已损坏 / Local backup corrupted") }
        }
        if let expected = backup.remoteReceiptHash {
            let root = preview.directory.appendingPathComponent("remote")
            guard try hashFile(root.appendingPathComponent("receipt.json")) == expected else { throw AppFailure("云端备份记录已损坏 / Remote backup receipt corrupted") }
            let receipt = try FileStore.decode(NativeReceipt.self, at: root.appendingPathComponent("receipt.json"))
            guard receipt.provider == preview.source.provider, receipt.account == preview.account, receipt.app == String(preview.app), receipt.files.count == preview.remote.count else { throw AppFailure("云端备份账号或游戏不匹配 / Remote backup account or game mismatch") }
            for (index, file) in receipt.files.enumerated() {
                let original = preview.remote[index]
                guard file.path == original.path, file.size == original.size, file.modifiedTime == original.modifiedTime, let sha = file.sha256, TextUtil.validKey(sha),
                      try FileStore.hash(FileStore.read(root.appendingPathComponent("objects/\(index).bin"))) == sha else { throw AppFailure("云端备份内容校验失败 / Remote backup content verification failed") }
            }
        }
    }
    public func delete(_ backup: CloudGameBackup) async throws {
        let preview = backup.preview, provider = try validate(backup.preview)
        try verifyBackup(backup); try validateLocal(preview, provider: provider)
        let status = preview.directory.appendingPathComponent("deletion-status.json")
        try FileStore.json(["state": "deleting"], to: status)
        do {
            if let receipt = backup.remoteReceiptHash {
                let output = try await execute(["delete-app-checked", provider.rawValue, preview.account, String(preview.app), preview.directory.appendingPathComponent("remote").path, receipt])
                let result = try CloudOnline.decodeLast(NativeDeleteResult.self, from: output)
                guard result.success, result.remaining == 0, result.deleted == preview.remote.count else { throw AppFailure("云端删除后回查未通过 / Remote deletion readback failed") }
            }
            _ = try validate(preview); try validateLocal(preview, provider: provider)
            for target in preview.local {
                try stopped()
                let original = URL(fileURLWithPath: target.path), retired = original.deletingLastPathComponent().appendingPathComponent(".fluent-delete-\(UUID().uuidString)")
                guard rename(original.path, retired.path) == 0 else { throw POSIXError(.EIO) }
                do {
                    guard try Self.snapshot(retired) == target.snapshot else { throw AppFailure("删除期间本地目录变化 / Local directory changed during deletion") }
                    try FileStore.fm.removeItem(at: retired)
                } catch {
                    if !FileStore.fm.fileExists(atPath: original.path) { _ = rename(retired.path, original.path) }
                    throw error
                }
                guard !FileStore.fm.fileExists(atPath: original.path) else { throw AppFailure("本地目录被其他进程重新创建 / Another process recreated the local directory") }
            }
            if ![.local, .folder].contains(provider) {
                guard try await remoteFiles(provider: provider, account: preview.account, app: preview.app).isEmpty else { throw AppFailure("云端出现残留或新对象 / Remote objects remain or were newly created") }
            }
            try FileStore.json(["state": "complete"], to: status)
        } catch {
            try? FileStore.json(["state": "failed-or-partial", "error": error.localizedDescription], to: status)
            throw AppFailure("删除未完全完成，可能已部分删除。已校验备份保留在：\(preview.directory.path)\n\(error.localizedDescription) / Deletion incomplete; verified backup retained")
        }
    }
}
