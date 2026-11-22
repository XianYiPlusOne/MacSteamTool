import CryptoKit
import Foundation

/// ConnectTool 1.6.0, including its mixed byte order on Windows x64.
enum MultiplayerWire {
    enum JoinTarget: Equatable {
        case lobby(UInt64), user(UInt64)

        init?(_ text: String) {
            guard let id = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                (1...4).contains(id >> 56)
            else { return nil }
            let instance = (id >> 32) & 0xfffff
            switch (id >> 52) & 15 {
            case 8 where instance & 0x40000 != 0: self = .lobby(id)
            case 1 where UInt32(truncatingIfNeeded: id) != 0 && instance == 1: self = .user(id)
            case 9: self = .user(id)
            default: return nil
            }
        }
    }

    enum VPN: UInt8, CaseIterable {
        case ip = 1, routes = 3, probe = 10, conflict = 11, announce = 12, release = 13
        case heartbeat = 14, heartbeatAck = 15, hello = 20
    }

    static func little64(_ n: UInt64) -> Data {
        withUnsafeBytes(of: n.littleEndian) { Data($0) }
    }

    static func ipv4(_ n: UInt32) -> Data {
        withUnsafeBytes(of: n.bigEndian) { Data($0) }
    }

    static func ipString(_ n: UInt32) -> String {
        ipv4(n).map(String.init).joined(separator: ".")
    }

    static func readIP(_ data: Data, at offset: Int = 0) -> UInt32 {
        data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    static func read64(_ data: Data, at offset: Int = 0) -> UInt64 {
        data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    static func node(_ steamID: UInt64) -> Data {
        Data(SHA256.hash(data: little64(steamID) + Data("ConnectTool_VPN_Salt_v1".utf8)))
    }

    static func candidate(node: Data, offset: UInt32) -> UInt32 {
        let hash = node.suffix(3).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return 0x0a00_0000 | (((hash &+ offset) & 0xffffff) % 0xfffffe + 1)
    }

    static func control(ip: UInt32, node: Data, timestamp: UInt64? = nil) -> Data {
        ipv4(ip) + node + (timestamp.map(little64) ?? Data())
    }

    static func envelope(_ kind: VPN, _ body: Data = Data()) -> Data? {
        guard body.count <= UInt16.max else { return nil }
        return Data([kind.rawValue, UInt8(body.count >> 8), UInt8(truncatingIfNeeded: body.count)]) + body
    }

    static func decodeVPN(_ bytes: Data) -> (VPN, Data)? {
        guard bytes.count >= 3, let type = VPN(rawValue: bytes[bytes.startIndex]) else { return nil }
        let prefix = bytes.prefix(3)
        let count = Int(prefix[prefix.startIndex + 1]) * 256 + Int(prefix[prefix.startIndex + 2])
        guard bytes.count >= 3 + count else { return nil }
        return (type, Data(bytes.dropFirst(3).prefix(count)))
    }

    struct Frame: Equatable {
        let id: String
        let close: Bool
        let payload: Data
    }

    static func encode(_ frame: Frame) -> Data? {
        let id = Array(frame.id.utf8)
        guard validID(id), !frame.close || frame.payload.isEmpty else { return nil }
        return Data(id + [0, frame.close ? 1 : 0, 0, 0, 0]) + frame.payload
    }

    static func decodeTCP(_ bytes: Data) -> Frame? {
        guard bytes.count >= 11 else { return nil }
        let header = Array(bytes.prefix(11))
        let id = Array(header.prefix(6))
        guard validID(id), header[6] == 0, header[7] < 2, header[8...] == [0, 0, 0],
            header[7] == 0 || bytes.count == 11
        else { return nil }
        return Frame(
            id: String(decoding: id, as: UTF8.self), close: header[7] == 1, payload: Data(bytes.dropFirst(11)))
    }

    private static func validID(_ bytes: [UInt8]) -> Bool {
        bytes.count == 6
            && bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
}
