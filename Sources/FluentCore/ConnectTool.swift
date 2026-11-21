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
    public var id: String { steamId }
}
public struct ConnectLobby: Decodable, Identifiable, Sendable {
    public var lobbyId: String
    public var name: String
    public var hostName: String
    public var hostId: String
    public var members: Int
    public var ping: Int
    public var id: String { lobbyId }
}
public struct ConnectChat: Decodable, Identifiable, Sendable {
    public var steamId: String?
    public var displayName: String?
    public var message: String?
    public var timestamp: String?
    public var isSelf: Bool?
    public var isPinned: Bool?
    public var row: Int?
    public var id: String { "\(steamId ?? "")|\(timestamp ?? "")|\(row ?? -1)" }
}
public struct ConnectPOP: Decodable, Identifiable, Sendable {
    public var name: String
    public var ping: Int
    public var via: String?
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
    public var publishLobby: Bool?
    public var hostSteamId: String?
    public var selfSteamId: String?
    public var joinTarget: String?
    public var roomName: String?
    public var localPort: Int?
    public var localBindPort: Int?
    public var tcpClients: Int?
    public var tunLocalIp: String?
    public var tunDeviceName: String?
    public var tunReady: Bool?
    public var relayPing: Int?
    public var relayPops: [ConnectPOP]?
    public var friendsRefreshing: Bool?
    public var lobbyRefreshing: Bool?
    public var friends: [ConnectPerson]?
    public var members: [ConnectPerson]?
    public var lobbies: [ConnectLobby]?
    public var messages: [ConnectChat]?
    public var pinned: ConnectChat?
    public var appVersion: String?
    public var latestVersion: String?
    public var updateAvailable: Bool?
    public var checkingUpdate: Bool?
    public var updateStatusText: String?
    public var latestReleasePage: String?
    public var downloadingUpdate: Bool?
    public var downloadProgress: Double?
    public var downloadSavedPath: String?
    public init() {}
    public var active: Bool { isHost == true || isConnected == true || !(lobbyId ?? "").isEmpty }
}
public struct ConnectEvent: Decodable, Sendable {
    public var type: String
    public var id: Int?
    public var state: ConnectState?
    public var message: String?
}
/// Bounded NDJSON framing also handles multiple events in a single pipe read.
public struct ConnectFrames {
    private var data = Data()
    public init() {}
    public mutating func append(_ chunk: Data) throws -> [ConnectEvent] {
        data.append(chunk)
        var events: [ConnectEvent] = []
        while let end = data.firstIndex(of: 10) {
            guard data.distance(from: data.startIndex, to: end) <= 32 * 1024 * 1024 else { throw AppFailure("联机服务响应过大 / Multiplayer response too large") }
            let line = data[..<end]; data.removeSubrange(...end)
            if !line.isEmpty { events.append(try JSONDecoder().decode(ConnectEvent.self, from: line)) }
        }
        guard data.count <= 32 * 1024 * 1024 else { throw AppFailure("联机服务响应过大 / Multiplayer response too large") }
        return events
    }
}
