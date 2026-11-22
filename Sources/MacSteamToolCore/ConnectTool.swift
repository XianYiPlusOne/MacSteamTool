import Foundation

public struct ConnectPerson: Decodable, Identifiable, Sendable {
    public var steamId: String
    public var displayName: String
    public var avatar: String?
    public var online: Bool?
    public var status: String?
    public var inviteCooldown: Int?
    public var isSelf: Bool?
    public var isFriend: Bool?
    public var ip: String?
    public var ping: Int?
    public var relay: String?
    public init(id: UInt64, name: String) { steamId = String(id); displayName = name }
    public var id: String { steamId }
}
public struct ConnectLobby: Decodable, Identifiable, Sendable {
    public var lobbyId: String
    public var name: String
    public var hostName: String
    public var hostId: String
    public var members: Int
    public var ping: Int
    public init(id: UInt64, name: String, host: UInt64, hostName: String, members: Int, ping: Int) {
        lobbyId = String(id); self.name = name; hostId = String(host); self.hostName = hostName
        self.members = members; self.ping = ping
    }
    public var id: String { lobbyId }
}
public struct ConnectChat: Codable, Identifiable, Sendable {
    public var steamId: String?
    public var displayName: String?
    public var message: String?
    public var timestamp: String?
    public var isSelf: Bool?
    public var isPinned: Bool?
    public init() {}
    public var row: Int?
    public var id: String { "\(steamId ?? "")|\(timestamp ?? "")|\(row ?? -1)" }
}
public struct ConnectPOP: Decodable, Identifiable, Sendable {
    public var name: String
    public var ping: Int
    public var via: String?
    public init(name: String, ping: Int, via: String?) { self.name = name; self.ping = ping; self.via = via }
    public var id: String { name }
}
public struct ConnectState: Decodable, Sendable {
    public var steamReady: Bool?
    public var isHost: Bool?
    public var isConnected: Bool?
    public var status: String?
    public var connectionMode: Int?
    public var lobbyId: String?
    public var lobbyName: String?
    public var hostSteamId: String?
    public var selfSteamId: String?
    public var localPort: Int?
    public var localBindPort: Int?
    public var tcpClients: Int?
    public var tunLocalIp: String?
    public var tunDeviceName: String?
    public var relayPing: Int?
    public var relayPops: [ConnectPOP]?
    public var lobbyRefreshing: Bool?
    public var friends: [ConnectPerson]?
    public var members: [ConnectPerson]?
    public var lobbies: [ConnectLobby]?
    public var messages: [ConnectChat]?
    public var pinned: ConnectChat?
    public init() {}
    public var active: Bool { isHost == true || isConnected == true || !(lobbyId ?? "").isEmpty }
    public var gameAddress: String? {
        guard active else { return nil }
        switch connectionMode {
        case 0:
            guard let port = isHost == true ? localPort : localBindPort, (1...65535).contains(port) else { return nil }
            return "localhost:\(port)"
        case 1:
            let ip = isHost == true ? tunLocalIp : members?.first { $0.steamId == hostSteamId }?.ip
            guard let ip, !ip.isEmpty else { return nil }
            return ip
        default:
            return nil
        }
    }
}
