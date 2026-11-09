import Foundation

/// Steam v5 manifest framing; see SteamRE/SteamKit DepotManifest and content_manifest.proto.
/// This verifies framing and payload integrity, not Valve's cryptographic signature.
public enum SteamManifest {
    public static let magic = Data([0xd0, 0x17, 0xf6, 0x71])
    public static func validate(_ data: Data, depot: Int, manifest: String) throws {
        guard TextUtil.validID(String(depot)) != nil, let gid = UInt64(manifest), gid > 0 else { throw AppFailure("无效的 Manifest 标识 / Invalid manifest identity") }
        let bytes = [UInt8](data)
        var offset = 0, sections: [UInt32: [UInt8]] = [:], payloadCRC = [UInt8](), ended = false
        func u32(_ start: Int) throws -> UInt32 {
            guard start >= 0, start + 4 <= bytes.count else { throw AppFailure("Manifest 分段被截断 / Truncated manifest section") }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << ($1 * 8) }
        }
        while offset < bytes.count {
            let type = try u32(offset); offset += 4
            if type == 0x32c415ab { ended = true; break }
            guard [0x71f617d0, 0x1f4812be, 0x1b81b817].contains(type), sections[type] == nil else { throw AppFailure("Manifest 包含未知或重复分段 / Manifest contains unknown or duplicate sections") }
            let length = Int(try u32(offset)); offset += 4
            guard length <= bytes.count - offset else { throw AppFailure("Manifest 分段长度无效 / Invalid manifest section length") }
            sections[type] = Array(bytes[offset..<(offset + length)])
            if type == 0x71f617d0 { payloadCRC = Array(bytes[(offset - 4)..<(offset + length)]) }
            offset += length
        }
        guard ended, offset == bytes.count, sections.count == 3, let metadata = sections[0x1f4812be] else { throw AppFailure("Manifest 缺少完整分段或结束标记 / Manifest is missing sections or its end marker") }
        let fields = try protobufNumbers(metadata)
        guard fields[1] == UInt64(depot), fields[2] == gid else { throw AppFailure("Manifest 内容与请求的 DepotID / ManifestID 不一致") }
        let expectedCRC = fields[(fields[4] ?? 0) != 0 ? 8 : 9] ?? 0
        if expectedCRC != 0, UInt64(crc32(payloadCRC)) != expectedCRC { throw AppFailure("Manifest 内容 CRC 校验失败 / Manifest content CRC mismatch") }
    }
    private static func protobufNumbers(_ bytes: [UInt8]) throws -> [Int: UInt64] {
        var i = 0, result: [Int: UInt64] = [:]
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard i < bytes.count else { throw AppFailure("Manifest 元数据被截断 / Truncated manifest metadata") }
                let b = bytes[i]; i += 1
                guard shift < 63 || b <= 1 else { throw AppFailure("Manifest 元数据整数溢出 / Manifest metadata integer overflow") }
                value |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return value }
            }
            throw AppFailure("Manifest 元数据整数无效 / Invalid manifest metadata integer")
        }
        while i < bytes.count {
            let tag = try varint(), field = Int(tag >> 3)
            guard field > 0 else { throw AppFailure("Manifest 元数据字段无效 / Invalid manifest metadata field") }
            switch tag & 7 {
            case 0: result[field] = try varint()
            case 1: i += 8
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - i) else { throw AppFailure("Manifest 元数据长度无效 / Invalid manifest metadata length") }
                i += Int(length)
            case 5: i += 4
            default: throw AppFailure("不支持的 Manifest 元数据编码 / Unsupported manifest metadata encoding")
            }
            guard i <= bytes.count else { throw AppFailure("Manifest 元数据被截断 / Truncated manifest metadata") }
        }
        return result
    }
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc = UInt32.max
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

public struct ManifestRequest: Hashable, Sendable {
    public var app: Int
    public var depot: Int
    public var manifest: String
    public var key: String { "\(depot)_\(manifest)" }
}

/// Bounded tail reader, including partial lines, truncation and rename-based log rotation.
public struct ContentLogTail {
    public let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var pending = Data()
    private var seen = Set<String>()
    public init(url: URL, fromEnd: Bool = true) throws {
        self.url = url
        let attributes = try FileStore.fm.attributesOfItem(atPath: url.path)
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        offset = fromEnd ? (attributes[.size] as? NSNumber)?.uint64Value ?? 0 : 0
    }
    public mutating func poll() throws -> [ManifestRequest] {
        let attributes = try FileStore.fm.attributesOfItem(atPath: url.path)
        let newInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if newInode != inode || size < offset { inode = newInode; offset = 0; pending.removeAll() }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let chunk = try handle.read(upToCount: 1_048_576) ?? Data(); offset += UInt64(chunk.count)
        pending.append(chunk)
        guard let last = pending.lastIndex(of: 10) else {
            guard pending.count < 1_048_576 else { throw AppFailure("Steam 日志单行过长 / Steam log line exceeds the length limit") }; return []
        }
        let text = String(decoding: pending[...last], as: UTF8.self)
        pending = Data(pending.dropFirst(last + 1))
        if seen.count > 10_000 { seen.removeAll() }
        return Self.parse(text).filter { seen.insert("\($0.app):\($0.key)").inserted }
    }
    /// A failed request can reappear in new Steam log lines after the user retries.
    public mutating func allowRetry(_ request: ManifestRequest) { seen.remove("\(request.app):\(request.key)") }
    public static func parse(_ text: String) -> [ManifestRequest] {
        TextUtil.matches(#"BYldRequestDepotManifest\(App:\s*(\d+),\s*Depot:\s*(\d+),\s*Manifest:\s*(\d+)"#, text).compactMap {
            guard let app = TextUtil.validID($0[1]), let depot = TextUtil.validID($0[2]), let manifest = UInt64($0[3]), manifest > 0 else { return nil }
            return ManifestRequest(app: app, depot: depot, manifest: String(manifest))
        }
    }
}
