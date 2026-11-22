import Foundation
import MacSteamToolCore
import Network

@MainActor final class MultiplayerTCP {
    typealias Frame = MultiplayerWire.Frame
    struct Key: Hashable {
        let connection: UInt32
        let id: String
    }
    @MainActor private final class Stream {
        let socket: NWConnection
        var queued = 0
        var pending: Data?
        var remoteClosed = false
        init(_ socket: NWConnection) { self.socket = socket }
    }

    private let sdk: MultiplayerSDK
    private let host: Bool
    private let gamePort: NWEndpoint.Port
    private let onFailure: (String) -> Void
    private var listener: NWListener?
    private var waiting = [NWConnection]()
    private var streams = [Key: Stream]()
    private var connections = [UInt32: UInt64]()
    private var ready = Set<UInt32>()
    private(set) var listenSocket: UInt32 = 0
    private var relayAttempt = false
    private var connectingSince: TimeInterval = 0
    private var target: UInt64 = 0
    var count: Int { streams.count }
    var connected: Bool { !ready.isEmpty }
    var peers: [UInt32: UInt64] { connections.filter { ready.contains($0.key) } }

    init(sdk: MultiplayerSDK, host: Bool, gamePort: UInt16, onFailure: @escaping (String) -> Void) {
        self.sdk = sdk
        self.host = host
        self.gamePort = NWEndpoint.Port(rawValue: gamePort)!
        self.onFailure = onFailure
    }

    func start(peer: UInt64, bindPort: UInt16) throws {
        if host {
            listenSocket = sdk.api.listen()
            guard listenSocket != 0 else { throw AppFailure("无法监听 Steam P2P 端口 / Steam listen failed") }
            return
        }
        target = peer
        try dial(relay: false)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: bindPort)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                if case .failed(let error) = state { self.onFailure(error.localizedDescription) }
            }
        }
        listener.newConnectionHandler = { [weak self] socket in
            MainActor.assumeIsolated {
                guard let self, self.listener != nil else {
                    socket.cancel()
                    return
                }
                if let h = self.ready.first {
                    self.attach(socket, to: h)
                } else if self.waiting.count < 64 {
                    self.waiting.append(socket)
                } else {
                    socket.cancel()
                }
            }
        }
        listener.start(queue: .main)
    }

    private func attach(_ socket: NWConnection, to handle: UInt32) {
        guard streams.count < 1024 else {
            socket.cancel()
            return
        }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var key: Key
        repeat {
            key = Key(connection: handle, id: String((0..<6).map { _ in alphabet.randomElement()! }))
        } while streams[key] != nil || pendingCloses[key] != nil
        open(key, socket: socket)
    }

    private func dial(relay: Bool) throws {
        let h = sdk.api.connect(target, relay)
        guard h != 0 else { throw AppFailure("无法连接房主 / Steam connection failed") }
        connections[h] = target
        relayAttempt = relay
        connectingSince = ProcessInfo.processInfo.systemUptime
    }

    func status(handle: UInt32, peer: UInt64, listener: UInt32, state: Int32, allow: Bool) {
        if state == 1 && listener != 0 {
            guard host, listener == listenSocket, allow, sdk.api.accept(handle) else {
                sdk.api.closeTCP(handle)
                return
            }
            connections[handle] = peer
        }
        guard connections[handle] != nil else { return }
        if state == 3 {
            ready.insert(handle)
            for socket in waiting { attach(socket, to: handle) }
            waiting.removeAll()
        }
        if state == 4 || state == 5 {
            let hadConnection = ready.contains(handle)
            remove(handle)
            if !host {
                if !hadConnection && !relayAttempt {
                    do { try dial(relay: true) } catch { onFailure(error.localizedDescription) }
                } else {
                    onFailure("与房主的连接已断开 / Host disconnected")
                }
            }
        }
    }

    private func open(_ key: Key, socket: NWConnection) {
        let stream = Stream(socket)
        streams[key] = stream
        socket.stateUpdateHandler = { [weak self, weak stream] state in
            MainActor.assumeIsolated {
                guard let self, let stream, self.streams[key] === stream else { return }
                switch state {
                case .ready: self.read(key, stream)
                case .failed: self.close(key, notify: true)
                default: break
                }
            }
        }
        socket.start(queue: .main)
    }
    private func read(_ key: Key, _ stream: Stream) {
        guard !stream.remoteClosed else { return }
        stream.socket.receive(minimumIncompleteLength: 1, maximumLength: 1100) {
            [weak self, weak stream] bytes, _, eof, error in
            MainActor.assumeIsolated {
                guard let self, let stream, self.streams[key] === stream, !stream.remoteClosed else { return }
                if let bytes, !bytes.isEmpty {
                    stream.pending = MultiplayerWire.encode(Frame(id: key.id, close: false, payload: bytes))
                    // TCP may deliver its final bytes together with EOF.
                    self.flush(key, stream, eof: eof || error != nil)
                } else if eof || error != nil {
                    self.close(key, notify: true)
                } else {
                    self.read(key, stream)
                }
            }
        }
    }
    private var closingAfterSend = Set<Key>()
    private func flush(_ key: Key, _ stream: Stream, eof: Bool) {
        guard let bytes = stream.pending else { return }
        let result = bytes.withUnsafeBytes { sdk.api.sendTCP(key.connection, $0.baseAddress, Int32($0.count)) }
        if result == 25 {  // k_EResultLimitExceeded: preserve order and retry on the next tick.
            if eof { closingAfterSend.insert(key) }
            return
        }
        stream.pending = nil
        if result != 1 || eof || closingAfterSend.contains(key) {
            close(key, notify: true)
        } else {
            read(key, stream)
        }
    }
    private var pendingCloses = [Key: Data]()
    private func close(_ key: Key, notify: Bool) {
        guard let stream = streams.removeValue(forKey: key) else { return }
        closingAfterSend.remove(key)
        stream.socket.cancel()
        if notify, let bytes = MultiplayerWire.encode(Frame(id: key.id, close: true, payload: Data())) {
            pendingCloses[key] = bytes
        }
    }
    private func receive(_ frame: Frame, handle: UInt32) {
        let key = Key(connection: handle, id: frame.id)
        if frame.close {
            if let stream = streams[key] {
                stream.remoteClosed = true
                if stream.queued == 0 { close(key, notify: false) }
            }
            return
        }
        guard pendingCloses[key] == nil else { return }
        if host && streams[key] == nil && streams.count < 1024 {
            open(key, socket: NWConnection(host: "127.0.0.1", port: gamePort, using: .tcp))
        }
        guard let stream = streams[key] else {
            pendingCloses[key] = MultiplayerWire.encode(Frame(id: key.id, close: true, payload: Data()))
            return
        }
        guard !stream.remoteClosed, !frame.payload.isEmpty else { return }
        stream.queued += frame.payload.count
        guard stream.queued <= 4 * 1024 * 1024 else {
            close(key, notify: true)
            return
        }
        stream.socket.send(
            content: frame.payload,
            completion: .contentProcessed { [weak self, weak stream] error in
                MainActor.assumeIsolated {
                    guard let self, let stream, self.streams[key] === stream else { return }
                    stream.queued -= frame.payload.count
                    if error != nil || (stream.remoteClosed && stream.queued == 0) {
                        self.close(key, notify: !stream.remoteClosed)
                    }
                }
            })
    }
    func tick() {
        if !host, !relayAttempt, ready.isEmpty, ProcessInfo.processInfo.systemUptime - connectingSince > 12,
            let h = connections.keys.first
        {
            remove(h)
            do { try dial(relay: true) } catch {
                onFailure(error.localizedDescription)
                return
            }
        }
        for h in ready {
            for (_, bytes) in sdk.packets(connection: h) {
                if let frame = MultiplayerWire.decodeTCP(bytes) { receive(frame, handle: h) }
            }
        }
        for (key, stream) in streams where stream.pending != nil { flush(key, stream, eof: false) }
        for (key, bytes) in pendingCloses {
            let result = bytes.withUnsafeBytes { sdk.api.sendTCP(key.connection, $0.baseAddress, Int32($0.count)) }
            if result != 25 { pendingCloses.removeValue(forKey: key) }
        }
    }
    private func remove(_ h: UInt32) {
        for key in streams.keys where key.connection == h { close(key, notify: false) }
        pendingCloses = pendingCloses.filter { $0.key.connection != h }
        ready.remove(h)
        connections.removeValue(forKey: h)
        sdk.api.closeTCP(h)
    }
    func stop() {
        listener?.cancel()
        listener = nil
        for socket in waiting { socket.cancel() }
        waiting.removeAll()
        for h in Array(connections.keys) { remove(h) }
        if listenSocket != 0 {
            sdk.api.closeListen(listenSocket)
            listenSocket = 0
        }
    }
}
