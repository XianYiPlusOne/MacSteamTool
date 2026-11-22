import Foundation

public enum Saves {
    public static func backup(_ sourceURL: URL, to destinationURL: URL) throws -> Int {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw AppFailure("存档源必须是实际存在的目录 / Save source must be an existing directory") }
        guard !FileStore.fm.fileExists(atPath: destination.path), !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw AppFailure("备份目标必须是新的独立目录 / Backup destination must be a new, separate directory") }
        for reserved in [".fluent-checksums.json", ".INCOMPLETE"] {
            guard !FileStore.fm.fileExists(atPath: source.appendingPathComponent(reserved).path) else { throw AppFailure("所选目录包含备份元数据；请选择实际的游戏存档目录 / Folder contains backup metadata; select the actual game save directory") }
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let iterator = FileStore.fm.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in enumerationError = error; return false }) else { throw AppFailure("无法读取存档目录 / Cannot read the save directory") }
        var snapshots: [(URL, String, Int, Date?)] = []; var size = 0
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { iterator.skipDescendants(); throw AppFailure("存档目录包含符号链接，请选择实际存档目录 / Save directory contains symbolic links; select the actual directory") }
            if values.isRegularFile == true {
                let actual = file.standardizedFileURL
                guard actual.path.hasPrefix(source.path + "/") else { throw AppFailure("存档枚举返回了目录外的文件 / A save file resolves outside the selected directory") }
                let relative = String(actual.path.dropFirst(source.path.count + 1)); size += values.fileSize ?? 0
                guard size <= 8 * 1024 * 1024 * 1024 else { throw AppFailure("此目录超过 8 GB，请选择更具体的存档子目录 / Directory exceeds 8 GB; select a smaller save subdirectory") }
                snapshots.append((file, relative, values.fileSize ?? 0, values.contentModificationDate))
            }
        }
        if let enumerationError { throw enumerationError }
        try FileStore.mkdir(destination)
        var checksums: [String: String] = [:]
        do {
            for (file, relative, size, date) in snapshots {
                let target = destination.appendingPathComponent(relative)
                try FileStore.mkdir(target.deletingLastPathComponent()); try FileStore.fm.copyItem(at: file, to: target)
                let now = try file.resourceValues(forKeys: keys)
                guard now.fileSize == size, now.contentModificationDate == date else { throw AppFailure("备份过程中存档发生变化，请退出游戏后重试 / Save changed during backup; close the game and retry") }
                let original = FileStore.hash(try FileStore.read(file)); let copied = FileStore.hash(try FileStore.read(target))
                guard original == copied else { throw AppFailure("备份校验失败 / Backup verification failed：\(relative)") }; checksums[relative] = original
            }
            try FileStore.json(checksums, to: destination.appendingPathComponent(".fluent-checksums.json"))
            return snapshots.count
        } catch {
            // Leave incomplete copies for inspection, explicitly marked; never delete the source.
            try? FileStore.write(Data(error.localizedDescription.utf8), to: destination.appendingPathComponent(".INCOMPLETE")); throw error
        }
    }
}
