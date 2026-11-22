import CArchive
import Darwin
import Foundation

/// Read one entry at a time, including solid archives. Never let an archive choose an
/// on-disk path until the complete relative name and entry type have been checked.
public enum NativeArchive {
    static func read(_ url: URL, library: Bool, password: String = "",
                     directory: (String) throws -> Void = { _ in }, visit: (String, Data) throws -> Void) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AppFailure("无法打开压缩包 / Cannot open archive") }
        defer { close(fd) }
        var stat = Darwin.stat()
        guard fstat(fd, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG,
              stat.st_size <= 2 * 1024 * 1024 * 1024 else { throw AppFailure("Invalid archive or input exceeds 2 GiB") }
        guard let reader = archive_read_new() else { throw AppFailure("Cannot initialize archive reader") }
        defer { archive_read_free(reader) }
        func check(_ status: Int32) throws {
            guard status == 0 else {
                throw AppFailure(archive_error_string(reader).map { String(cString: $0) } ?? "Invalid or damaged archive")
            }
        }
        try check(archive_read_support_filter_gzip(reader))
        try check(archive_read_support_filter_bzip2(reader))
        try check(archive_read_support_filter_xz(reader))
        try check(archive_read_support_format_zip(reader))
        try check(archive_read_support_format_tar(reader))
        try check(archive_read_support_format_7zip(reader))
        try check(archive_read_support_format_rar(reader))
        try check(archive_read_support_format_rar5(reader))
        if !password.isEmpty { try check(archive_read_add_passphrase(reader, password)) }
        try check(archive_read_open_fd(reader, fd, 65536))
        let entryLimit = (library ? 64 : 256) * 1024 * 1024
        let totalLimit = (library ? 256 : 512) * 1024 * 1024
        var rar = RARChecksums(fd: fd, length: stat.st_size)
        var seen = Set<String>(), directories = Set<String>(), regular = Set<String>()
        var expanded = 0, selected = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            try check(status)
            guard let entry, let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
                  var name = String(validatingUTF8: raw), name.utf8.count <= 1024 else { throw AppFailure("Invalid archive entry name") }
            let format = archive_format(reader) & 0xff0000
            if (format == 0xD0000 || format == 0x100000) && rar == nil {
                throw AppFailure("Unsupported RAR container")
            }
            let expectedCRC = try rar?.next()
            let kind = archive_entry_filetype(entry)
            if kind == S_IFDIR, name.hasSuffix("/") { name.removeLast() }
            name = name.replacingOccurrences(of: "\\", with: "/")
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard kind == S_IFDIR || kind == S_IFREG,
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                  !name.contains(":"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasSuffix(" ") || $0.hasSuffix(".") }),
                  seen.insert(key).inserted, seen.count <= (library ? 4096 : 10000),
                  !(kind == S_IFREG && directories.contains(key)) else { throw AppFailure("不安全或重复的压缩包路径 / Unsafe or duplicate archive path: " + name) }
            var parent = ""
            for part in parts.dropLast() {
                parent += (parent.isEmpty ? "" : "/") + part.precomposedStringWithCanonicalMapping.lowercased()
                guard !regular.contains(parent) else { throw AppFailure("Archive path traverses a file") }
                directories.insert(parent)
            }
            if kind == S_IFDIR {
                directories.insert(key)
                try directory(name)
                continue
            }
            regular.insert(key)
            let size = archive_entry_size(entry)
            guard size >= 0, size <= entryLimit, size <= totalLimit - expanded else { throw AppFailure("Expanded archive exceeds size limit") }
            expanded += Int(size)
            let keep = !library || ["lua", "manifest", "bin"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
            var data = Data(), count = 0
            var crc: UInt = 0
            while true {
                try Task.checkCancellation()
                let n = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                if n == 0 { break }
                guard n > 0, n <= size - Int64(count) else { throw AppFailure("Archive checksum or size mismatch: " + name) }
                if expectedCRC != nil { crc = buffer.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, UInt32(n)) } }
                count += n
                if keep { data.append(contentsOf: buffer.prefix(n)) }
            }
            guard count == size else { throw AppFailure("Truncated archive entry: " + name) }
            if let expectedCRC, UInt32(crc) != expectedCRC { throw AppFailure("RAR checksum mismatch: " + name) }
            if keep { try visit(name, data); selected += 1 }
        }
        guard selected > 0 else { throw AppFailure("压缩包内没有可用文件 / No supported files in archive") }
    }

    @discardableResult public static func extract(_ url: URL, to destination: URL, password: String = "") throws -> [String: String] {
        let parent = destination.deletingLastPathComponent()
        try FileStore.mkdir(parent)
        let stage = parent.appendingPathComponent(".archive-" + UUID().uuidString)
        try FileStore.fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileStore.fm.removeItem(at: stage) }
        var hashes: [String: String] = [:]
        try read(url, library: false, password: password, directory: { name in
            try FileStore.mkdir(stage.appendingPathComponent(name))
        }) { name, bytes in
            let output = stage.appendingPathComponent(name)
            try FileStore.mkdir(output.deletingLastPathComponent())
            try bytes.write(to: output, options: .withoutOverwriting)
            hashes[name] = FileStore.hash(bytes)
        }
        try Task.checkCancellation()
        try FileStore.fm.moveItem(at: stage, to: destination)
        return hashes
    }
}
