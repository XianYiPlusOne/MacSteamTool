import Foundation
import Darwin

public struct CachedSteamTicket: Codable, Sendable {
    public var enabled: Bool
    public let ownership: String
    public let encrypted: String
    public private(set) var embeddedAppID: Int?
    public private(set) var appIDOffset: Int?
    public private(set) var signatureOffset: Int?
    public var appID: Int { embeddedAppID ?? ((try? Self.decodeHex(ownership)).map { $0.count >= 20 ? Int(Self.u32($0, 16)) : 0 } ?? 0) }
    public var steamID: UInt64 { guard let d = try? Self.decodeHex(ownership), d.count >= 16 else { return 0 }; return (0..<8).reduce(0) { $0 | UInt64(d[8 + $1]) << ($1 * 8) } }
    public static func layout(_ data: Data, appID: Int) throws -> (app: Int, signature: Int) {
        guard let id = UInt32(exactly: appID), id > 0, (148...4096).contains(data.count),
              data[8..<16].contains(where: { $0 != 0 }) else { throw AppFailure("票据长度或账号无效 / Invalid ticket size or account") }
        let signature = data.count - 128
        let descriptor = Self.u32(data, 4) == 4
        if descriptor {
            let offset = Int(Self.u32(data, 0))
            guard offset >= 16, offset <= signature - 4, Self.u32(data, offset) == id else { throw AppFailure("票据描述头无效 / Invalid ticket descriptor") }
            return (offset, signature)
        }
        guard Int(Self.u32(data, 0)) == signature, signature >= 20 else { throw AppFailure("票据签名边界无效 / Invalid ticket signature boundary") }
        if Self.u32(data, 16) == id { return (16, signature) }
        let matches = (16...(signature - 4)).filter { Self.u32(data, $0) == id }
        guard matches.count == 1, let offset = matches.first else { throw AppFailure("票据 AppID 缺失或位置不唯一 / Missing or ambiguous ticket AppID") }
        return (offset, signature)
    }
    public init(appID: Int, ownership: Data, encrypted: Data, enabled: Bool = false) throws {
        let layout = try Self.layout(ownership, appID: appID)
        guard !encrypted.isEmpty, encrypted.count <= 4096 else { throw AppFailure("加密票据长度无效 / Invalid encrypted ticket length") }
        self.embeddedAppID = appID; self.appIDOffset = layout.app; self.signatureOffset = layout.signature
        self.ownership = ownership.map { String(format: "%02x", $0) }.joined()
        self.encrypted = encrypted.map { String(format: "%02x", $0) }.joined(); self.enabled = enabled
    }
    public static func decodeHex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count <= 8192, !bytes.isEmpty, bytes.count % 2 == 0 else { throw AppFailure("票据不是有效的十六进制数据 / Ticket is not valid hexadecimal data") }
        var data = Data(); data.reserveCapacity(bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[i...i + 1], as: UTF8.self), radix: 16) else { throw AppFailure("票据包含无效字符 / Ticket contains invalid characters") }; data.append(value)
        }
        return data
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) } }
    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 100_000 else { throw AppFailure("票据文件过大 / Ticket file exceeds the size limit") }
        var app: Int?, ownership: Data?, encrypted: Data?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if key == "appid" { app = TextUtil.validID(parts[1]) }
            if key.hasPrefix("appticket(") || key == "appticket" { ownership = try decodeHex(parts[1]) }
            if key.hasPrefix("eticket(") || key == "eticket" { encrypted = try decodeHex(parts[1]) }
        }
        guard let app, let ownership, let encrypted else { throw AppFailure("需要 appid、appticket 和 eticket 三项 / appid, appticket and eticket are all required") }
        return try Self(appID: app, ownership: ownership, encrypted: encrypted)
    }
    public func validate(appID: Int) throws {
        let parsed = try Self(appID: appID, ownership: Self.decodeHex(ownership), encrypted: Self.decodeHex(encrypted))
        guard (embeddedAppID == nil || embeddedAppID == parsed.embeddedAppID),
              (appIDOffset == nil || appIDOffset == parsed.appIDOffset),
              (signatureOffset == nil || signatureOffset == parsed.signatureOffset) else { throw AppFailure("票据元数据与内容不符 / Ticket metadata does not match its content") }
    }
}

public enum FriendPresence: String, Codable, CaseIterable, Sendable {
    case automatic, unchanged, selected, none
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer(), value = try container.decode(String.self)
        if value == "spacewar" { self = .selected; return }
        guard let mode = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown presence mode") }
        self = mode
    }
}
public struct ManifestProviderConfiguration: Codable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case macsteam, steam, custom }
    public var mode: Mode = .macsteam
    public var url = "https://steamapi.993499094.xyz/manifest/{depot}/{manifest}"
    public var apps: [String] = []
    public init() {}
    public func validate() throws {
        guard apps.count <= 4096, apps.allSatisfy({ TextUtil.validID($0) != nil }), mode == .macsteam || !apps.isEmpty else { throw AppFailure("Manifest Provider 需要明确的 AppID 列表 / Select AppIDs for the manifest provider") }
        guard mode == .custom else { return }
        var expanded = url
        for key in ["app", "depot", "manifest"] { expanded = expanded.replacingOccurrences(of: "{\(key)}", with: "1") }
        guard url.utf8.count <= 2048, url.contains("{manifest}"), !expanded.contains(where: { $0.isWhitespace || "{}\\".contains($0) }),
              let u = URLComponents(string: expanded), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil, u.fragment == nil,
              u.scheme == "https" || (u.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(host) && u.port != nil)
        else { throw AppFailure("Provider URL 需要 HTTPS 和 {manifest}，本地服务仅允许回环地址 / Use HTTPS with {manifest}, or a loopback HTTP provider") }
    }
}
public struct RuntimeFeatures: Codable, Sendable {
    public var presence: FriendPresence = .automatic
    public var presenceApps: [String: String] = [:]
    public var tickets: [String: CachedSteamTicket] = [:]
    public var manifestProvider: ManifestProviderConfiguration?
    public init() {}
    public static func url(paths: AppPaths) -> URL { paths.data.appendingPathComponent("CloudRedirect/runtime.json") }
    public static func load(paths: AppPaths) throws -> Self {
        let url = url(paths: paths)
        guard FileStore.fm.fileExists(atPath: url.path) else { return Self() }
        let value = try FileStore.decode(Self.self, at: url)
        try value.manifestProvider?.validate()
        for (key, ticket) in value.tickets { guard let id = TextUtil.validID(key) else { throw AppFailure("票据 AppID 无效 / Invalid ticket AppID") }; try ticket.validate(appID: id) }
        return value
    }
    public func save(paths: AppPaths) throws {
        try manifestProvider?.validate()
        for (key, ticket) in tickets { guard let id = TextUtil.validID(key) else { throw AppFailure("票据 AppID 无效 / Invalid ticket AppID") }; try ticket.validate(appID: id) }
        guard presenceApps.count <= 4096, tickets.count <= 1024, presenceApps.allSatisfy({ TextUtil.validID($0.key) != nil && $0.value.utf8.count <= 512 && !$0.value.contains("\0") }) else { throw AppFailure("广播游戏列表无效 / Invalid presence game list") }
        let url = Self.url(paths: paths), folder = url.deletingLastPathComponent()
        try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = folder.appendingPathComponent(".runtime-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: tmp) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard FileStore.fm.createFile(atPath: tmp.path, contents: try encoder.encode(self), attributes: [.posixPermissions: 0o600]), rename(tmp.path, url.path) == 0 else { throw AppFailure("无法安全保存运行时配置 / Cannot safely save runtime configuration") }
    }
}


public struct RuntimeFeatureStatus: Codable, Sendable {
    public let pid: Int32
    public let tickets: Bool
    public let presence: Bool
    public let playtimeWriter: Bool
    public let statistics: Bool
    public let playtime: Bool
    public let ownershipServed: UInt
    public let encryptedServed: UInt
    public let callbacksServed: UInt
    public let gamesObserved: UInt
    public let presenceChanged: UInt
    public let presenceMode: String?
    public let presenceAppsLoaded: UInt?
    public let presenceSent: UInt?
    public let presenceFailures: UInt?
    public let presenceLastAppID: UInt?
    public let presenceIdentity: String?
    public let presenceShortcutsLoaded: UInt?
    public let presenceLastGameID: UInt64?
    public let presenceLastSentAt: UInt64?
    public let accessTokenRequests: UInt?
    public let accessTokensLoaded: UInt?
    public let manifestProvider: Bool?
    public let manifestServed: UInt?
    public let manifestFallbacks: UInt?
    public let onlineFix: Bool?
    public let onlineFixAppID: UInt?
    public static func current(paths: AppPaths) -> Self? {
        guard let value = try? FileStore.decode(Self.self, at: paths.data.appendingPathComponent("CloudRedirect/runtime-status.json")), SteamProcesses.pids().contains(value.pid) else { return nil }
        return value
    }
}
