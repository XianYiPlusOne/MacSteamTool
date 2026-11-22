import CArchive
import Darwin
import Foundation

/// macOS libarchive can return successfully for damaged RAR payloads. Walk the
/// outer record headers on the same file descriptor and verify CRCs as data streams.
struct RARChecksums {
    private let fd: Int32
    private let length: Int64
    private let rar5: Bool
    private var offset: Int64
    private var records = 0

    init?(fd: Int32, length: Int64) {
        var marker = [UInt8](repeating: 0, count: 8)
        guard pread(fd, &marker, 8, 0) == 8,
              marker.prefix(6).elementsEqual([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) else { return nil }
        guard marker[6] == 0 || (marker[6] == 1 && marker[7] == 0) else { return nil }
        self.fd = fd; self.length = length; rar5 = marker[6] == 1; offset = rar5 ? 8 : 7
    }
    private var invalid: AppFailure { AppFailure("RAR 文件头无效 / Invalid RAR checksum header") }

    private func read(_ count: Int, at position: Int64) throws -> [UInt8] {
        guard position >= 0, position <= length, count <= length - position else { throw invalid }
        var bytes = [UInt8](repeating: 0, count: count)
        guard pread(fd, &bytes, count, position) == count else { throw invalid }
        return bytes
    }
    private func number(_ data: [UInt8], _ index: Int, _ count: Int) -> UInt32 {
        (0..<count).reduce(0) { $0 | UInt32(data[index + $1]) << ($1 * 8) }
    }
    private func vint(_ bytes: [UInt8], _ index: inout Int) throws -> Int64 {
        var value: Int64 = 0
        for shift in stride(from: 0, through: 56, by: 7) {
            guard index < bytes.count else { throw invalid }
            let byte = bytes[index]; index += 1
            value |= Int64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw invalid
    }
    private mutating func advance(_ dataLength: Int64) throws {
        guard dataLength >= 0, dataLength <= length - offset else { throw invalid }
        offset += dataLength
    }

    /// File records, including directories, are returned in decompressor order.
    mutating func next() throws -> UInt32? {
        while offset < length {
            try Task.checkCancellation()
            records += 1
            guard records <= 40000 else { throw invalid }
            if rar5 {
                let prefix = try read(Int(min(7, length - offset)), at: offset)
                var cursor = 4
                let size = try vint(prefix, &cursor)
                guard (1...2097152).contains(size) else { throw invalid }
                let header = try read(cursor + Int(size), at: offset)
                let checksum = header.withUnsafeBytes { raw in
                    UInt32(crc32(0, raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 4), UInt32(header.count - 4)))
                }
                guard checksum == number(header, 0, 4) else { throw invalid }
                let type = try vint(header, &cursor), flags = try vint(header, &cursor)
                if flags & 1 != 0 { _ = try vint(header, &cursor) }
                let packed = flags & 2 != 0 ? try vint(header, &cursor) : 0
                try advance(Int64(header.count))
                try advance(packed)
                if type == 5 { break }
                if type != 2 { continue }
                guard flags & 0x18 == 0 else { throw invalid }
                let fileFlags = try vint(header, &cursor)
                _ = try vint(header, &cursor) // uncompressed size
                _ = try vint(header, &cursor) // OS attributes
                if fileFlags & 2 != 0 { cursor += 4 } // optional Unix mtime
                guard fileFlags & 4 != 0 else { return nil }
                guard cursor <= header.count - 4 else { throw invalid }
                return number(header, cursor, 4)
            } else {
                let prefix = try read(7, at: offset)
                let size = Int(number(prefix, 5, 2)), flags = number(prefix, 3, 2)
                guard size >= 7 else { throw invalid }
                let header = try read(size, at: offset)
                let checksum = header.withUnsafeBufferPointer { bytes in
                    UInt32(crc32(0, bytes.baseAddress!.advanced(by: 2), UInt32(size - 2)))
                }
                guard checksum & 0xffff == number(header, 0, 2) else { throw invalid }
                var packed: Int64 = 0
                if flags & 0x8000 != 0 {
                    guard size >= 11 else { throw invalid }
                    packed = Int64(number(header, 7, 4))
                }
                let type = header[2]
                if type == 0x74 || type == 0x7a, flags & 0x100 != 0 {
                    guard size >= 40, number(header, 32, 4) == 0 else { throw invalid } // input is capped at 2 GiB
                }
                try advance(Int64(size))
                try advance(packed)
                if type == 0x7b { break }
                if type != 0x74 { continue }
                guard size >= 32, flags & 3 == 0 else { throw invalid }
                return number(header, 16, 4)
            }
        }
        throw invalid
    }
}
