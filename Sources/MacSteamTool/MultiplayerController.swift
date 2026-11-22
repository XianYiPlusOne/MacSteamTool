import AppKit
import CMultiplayer
import MacSteamToolCore

@MainActor final class MultiplayerController: ObservableObject {
    @Published var state = ConnectState()
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var steamLaunchError: String?
    @Published var failure: String?
    @Published var mode = 1
    @Published var roomName = ""
    @Published var target = ""
    @Published var port = "25565"
    @Published var bindPort = "8888"
    @Published var published = false
    @Published var draft = ""
    @Published var friendFilter = ""
    @Published var lobbyFilter = ""
    @Published var lobbySort = 0
    @Published var reminders = true
    let tun = TunHelperController()
    private let library: URL
    private let openSteam: @MainActor () async throws -> Void
    private var steamLaunchTask: Task<Void, Never>?
    var sdk: MultiplayerSDK?
    var me: UInt64 = 0
    var lobby: UInt64 = 0
    var hostID: UInt64 = 0
    var tcp: MultiplayerTCP?
    var lan: MultiplayerLAN?
    var members = Set<UInt64>()
    var direct = Set<UInt64>()
    var listCall: UInt64 = 0
    var listStarted: TimeInterval = 0
    var rooms = [ConnectLobby]()
    var cooldown = [UInt64: TimeInterval]()
    var avatars = [UInt64: String]()
    var pings = [UInt64: (Int, String)]()
    private var roomCall: UInt64 = 0
    private var requestedLobby: UInt64?
    private var deferredLeave: UInt64?
    private var activity: NSObjectProtocol?
    private var creating = false
    private var roomStarted: TimeInterval = 0
    private var nextCheck: TimeInterval = 0
    private var nextRefresh: TimeInterval = 0
    private var sessionPort: UInt16 = 25565
    private var sessionBind: UInt16 = 8888
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(
        library: URL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Resources/Helpers/ConnectTool/Frameworks/libMacMultiplayer.dylib"),
        openSteam: @escaping @MainActor () async throws -> Void
    ) {
        self.library = library
        self.openSteam = openSteam
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func start(steamRunning: Bool) {
        guard !running else { return }
        failure = nil
        do { if sdk == nil { sdk = try MultiplayerSDK(url: library) } } catch {
            failure = error.localizedDescription
            return
        }
        running = true
        nextCheck = steamRunning ? 0 : now + 3
        state.steamReady = false
        if steamRunning { tick() }
        if me == 0 { requestSteamLaunch() }
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
    func requestSteamLaunch() {
        guard running, me == 0, steamLaunchTask == nil else { return }
        steamLaunchError = nil
        steamLaunchTask = Task {
            defer { if !Task.isCancelled { steamLaunchTask = nil } }
            guard !Task.isCancelled, me == 0 else { return }
            do { try await openSteam() } catch {
                if !Task.isCancelled && me == 0 { steamLaunchError = error.localizedDescription }
            }
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        running = false
        resetSteamSession()
    }
    private func resetSteamSession() {
        steamLaunchTask?.cancel()
        steamLaunchTask = nil
        steamLaunchError = nil
        disconnect()
        sdk?.stop()
        me = 0
        listCall = 0
        nextCheck = now + 3
        nextRefresh = 0
        avatars.removeAll()
        rooms.removeAll()
        cooldown.removeAll()
        state = ConnectState()
    }
    private func tick() {
        guard running, let sdk else { return }
        if me == 0 {
            guard now >= nextCheck else { return }
            nextCheck = now + 3
            do { try sdk.start() } catch {
                state.status = error.localizedDescription
                state.steamReady = false
                return
            }
            me = sdk.api.user()
            guard me != 0 else {
                sdk.stop()
                state.steamReady = false
                return
            }
            steamLaunchError = nil
            state.steamReady = true
            state.selfSteamId = String(me)
            state.status = nil
            refreshFriends()
            refreshLobbies()
        }
        for event in sdk.events() {
            guard running, me != 0 else { return }
            handle(event, sdk)
        }
        guard running, me != 0 else { return }
        if roomCall != 0, now - roomStarted > 25 { fail("Steam 房间请求超时 / Room request timed out") }
        if listCall != 0, now - listStarted > 20 {
            listCall = 0
            state.lobbyRefreshing = false
        }
        tcp?.tick()
        do { try lan?.tick() } catch { fail(error.localizedDescription) }
        if now >= nextRefresh {
            nextRefresh = now + 2
            if sdk.api.user() != me {
                resetSteamSession()
                return
            }
            refreshMembers()
            refreshNetwork()
            if !cooldown.isEmpty { refreshFriends() }
        }
    }
    func fail(_ message: String) {
        disconnect()
        failure = message
    }

    func connect(host: Bool) {
        guard let sdk, me != 0, !state.active, tcp == nil, lan == nil, roomCall == 0 else { return }
        guard let p = UInt16(port), p > 0, let b = UInt16(bindPort), b > 0, roomName.utf8.count <= 128 else {
            failure = "请检查端口和房间名称 / Invalid room settings"
            return
        }
        failure = nil
        sessionPort = p
        sessionBind = b
        state.localPort = Int(p)
        state.localBindPort = Int(b)
        state.connectionMode = mode
        creating = host
        roomStarted = now
        if host {
            roomCall = sdk.api.create(250)
        } else {
            switch MultiplayerWire.JoinTarget(target) {
            case .lobby(let id):
                requestedLobby = id
                roomCall = sdk.api.join(id)
            case .user(let id):
                hostID = id
                beginTransport()
                return
            case nil:
                failure = "无效房间或 Steam ID / Invalid Steam ID"
                return
            }
        }
        if roomCall == 0 {
            fail("Steam 房间请求失败 / Room request failed")
        } else {
            starting = true
            state.status = "正在进入房间 / Opening room"
        }
    }
    func joinLobby(_ id: String) {
        guard !state.active, tcp == nil, lan == nil, roomCall == 0 else { return }
        target = id
        connect(host: false)
    }
    private func beginTransport() {
        guard let sdk else { return }
        do {
            if mode == 1 {
                lan = try MultiplayerLAN(sdk: sdk, me: me)
                if lobby == 0 {
                    direct.insert(hostID)
                    lan?.add(hostID)
                }
            } else {
                tcp = MultiplayerTCP(sdk: sdk, host: creating, gamePort: sessionPort) { [weak self] in
                    self?.fail($0)
                }
                try tcp?.start(peer: hostID, bindPort: sessionBind)
            }
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Multiplayer game connection")
            starting = tcp != nil && !creating
            state.connectionMode = mode
            state.isHost = creating
            state.isConnected = !creating && lan != nil
            state.hostSteamId = String(hostID)
            state.status = nil
            state.tunDeviceName = lan?.device
            refreshMembers()
        } catch { fail(error.localizedDescription) }
    }

    private func handle(_ event: MultiplayerSDK.Event, _ sdk: MultiplayerSDK) {
        let e = event.info
        switch UInt32(e.kind) {
        case MP_CREATED.rawValue, MP_ENTERED.rawValue:
            guard roomCall != 0, roomCall == e.call else {
                if e.lobby != 0 && e.lobby != lobby {
                    if e.lobby == requestedLobby { deferredLeave = e.lobby } else { sdk.api.leave(e.lobby) }
                }
                return
            }
            roomCall = 0
            starting = false
            guard e.lobby != 0 else {
                fail("Steam 未能创建或加入房间 / Lobby request rejected")
                return
            }
            requestedLobby = nil
            deferredLeave = nil
            lobby = e.lobby
            hostID = sdk.api.owner(lobby)
            guard hostID != 0 else {
                fail("房主已离开 / Owner unavailable")
                return
            }
            if creating {
                publishRoom(sdk)
            } else {
                mode = sdk.metadata(lobby, "ct_mode").lowercased() == "tun" ? 1 : 0
            }
            let key = sdk.api.presence(me, "connect").map(String.init(cString:)) ?? ""
            if key.isEmpty { _ = sdk.api.setPresence("connect", String(lobby)) }
            state.lobbyId = String(lobby)
            state.lobbyName = sdk.metadata(lobby, "ct_name")
            beginTransport()
            refreshPin()
        case MP_LIST.rawValue:
            if e.call == listCall {
                listCall = 0
                state.lobbyRefreshing = false
                receiveList(Int(e.value))
            }
        case MP_CHANGED.rawValue:
            if lobby != 0 && e.lobby == lobby {
                guard sdk.api.owner(lobby) == hostID else {
                    fail("房主已离开 / Host left")
                    return
                }
                refreshMembers()
                refreshPin()
            }
        case MP_INVITED.rawValue: joinLobby(String(e.lobby))
        case MP_CHAT.rawValue:
            if e.lobby == lobby && lobby != 0 { receiveChat(event.data, from: e.peer) }
        case MP_CONNECTION.rawValue:
            if let tcp {
                tcp.status(
                    handle: e.connection, peer: e.peer, listener: e.listener, state: e.value,
                    allow: state.isHost == true)
                if tcp.connected && state.isHost != true {
                    starting = false
                    state.isConnected = true
                }
            } else if e.listener != 0 {
                sdk.api.closeTCP(e.connection)
            }
        case MP_REQUEST.rawValue:
            if let lan, members.contains(e.peer) || direct.contains(e.peer) || state.isHost == true {
                if sdk.api.acceptVPN(e.peer) {
                    if !members.contains(e.peer) { direct.insert(e.peer) }
                    lan.add(e.peer, resetSession: false)
                }
            } else {
                sdk.api.closeVPN(e.peer)
            }
        case MP_SESSION_FAILED.rawValue:
            direct.remove(e.peer)
            lan?.remove(e.peer)
            if e.peer == hostID && hostID != me { fail("与房主的连接已断开 / Host disconnected") }
        case MP_KICKED.rawValue: if lobby == e.lobby { disconnect() }
        case MP_STEAM_LOST.rawValue:
            resetSteamSession()
        default: break
        }
    }
    private func publishRoom(_ sdk: MultiplayerSDK) {
        let name = sdk.name(me)
        let values = [
            "ct_mode": mode == 1 ? "tun" : "tcp", "ct_name": roomName.isEmpty ? name : roomName,
            "ct_host_id": String(me), "ct_host_name": name,
        ]
        for (key, value) in values { _ = sdk.api.setMetadata(lobby, key, value) }
        var location = [CChar](repeating: 0, count: 1024)
        if sdk.api.pingLocation(&location, 1024) { _ = sdk.api.setMetadata(lobby, "ct_ping_loc", &location) }
        if published { _ = sdk.api.setMetadata(lobby, "ct_tag", "1") }
    }
    func disconnect() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        if let deferredLeave, deferredLeave != lobby { sdk?.api.leave(deferredLeave) }
        requestedLobby = nil
        deferredLeave = nil
        tcp?.stop()
        tcp = nil
        lan?.stop()
        lan = nil
        if let sdk, me != 0, lobby != 0 {
            if sdk.api.presence(me, "connect").map(String.init(cString:)) == String(lobby) {
                _ = sdk.api.setPresence("connect", nil)
            }
            sdk.api.leave(lobby)
        }
        roomCall = 0
        creating = false
        starting = false
        lobby = 0
        hostID = 0
        members.removeAll()
        direct.removeAll()
        pings.removeAll()
        state.isHost = false
        state.isConnected = false
        state.lobbyId = nil
        state.hostSteamId = nil
        state.lobbyName = nil
        state.members = []
        state.messages = []
        state.pinned = nil
        state.status = nil
        state.tunDeviceName = nil
        state.tunLocalIp = nil
        state.tcpClients = 0
    }
}
