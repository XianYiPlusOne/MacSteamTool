import Darwin
import Foundation
import MacSteamToolCore

@MainActor final class MultiplayerLAN {
    private typealias Wire = MultiplayerWire
    private let sdk: MultiplayerSDK
    private let me: UInt64
    private let node: Data
    private let descriptor: Int32
    let device: String
    private(set) var address: UInt32 = 0
    private(set) var peers = Set<UInt64>()
    private var routes = [UInt32: UInt64]()
    private var seen = [UInt64: TimeInterval]()
    private var offset: UInt32 = 0
    private var candidate: UInt32 = 0
    private var deadline: TimeInterval = 0
    private var heartbeat: TimeInterval = 0
    private var conflicts = [UInt64: (node: Data, milliseconds: UInt64)]()
    private var buffer = [UInt8](repeating: 0, count: 65539)
    private var closed = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(sdk: MultiplayerSDK, me: UInt64) throws {
        self.sdk = sdk
        self.me = me
        node = Wire.node(me)
        var name = [CChar](repeating: 0, count: 32)
        var error = [CChar](repeating: 0, count: 512)
        descriptor = sdk.api.openTun(&name, 32, &error, 512)
        guard descriptor >= 0 else { throw AppFailure("虚拟网卡 / TUN: " + String(cString: error)) }
        device = String(cString: name)
        probe()
    }

    func peerAddress(_ peer: UInt64) -> String? {
        if peer == me { return address == 0 ? nil : Wire.ipString(address) }
        return routes.first { $0.value == peer }.map { Wire.ipString($0.key) }
    }
    func add(_ peer: UInt64, resetSession: Bool = true) {
        guard peer != me, peer != 0, peers.insert(peer).inserted else { return }
        seen[peer] = now
        if resetSession { sdk.api.closeVPN(peer) }
        _ = sdk.api.acceptVPN(peer)
        send(.hello, Data(), to: peer)
        advertise(to: peer)
    }
    func remove(_ peer: UInt64) {
        peers.remove(peer)
        routes = routes.filter { $0.value != peer }
        seen.removeValue(forKey: peer)
        conflicts.removeValue(forKey: peer)
        sdk.api.closeVPN(peer)
    }
    func stop() {
        guard !closed else { return }
        closed = true
        for peer in peers { remove(peer) }
        Darwin.close(descriptor)
    }
    private func send(_ type: Wire.VPN, _ body: Data, to peer: UInt64? = nil) {
        guard let bytes = Wire.envelope(type, body) else { return }
        bytes.withUnsafeBytes { raw in
            for id in peer.map({ [$0] }) ?? Array(peers) {
                _ = sdk.api.sendVPN(id, raw.baseAddress, Int32(raw.count), type != .ip, type == .hello)
            }
        }
    }
    private func advertise(to peer: UInt64? = nil) {
        guard address != 0 else {
            send(.probe, Wire.control(ip: candidate, node: node), to: peer)
            return
        }
        send(.announce, Wire.control(ip: address, node: node), to: peer)
        sendRoutes(to: peer)
    }
    private func sendRoutes(to peer: UInt64? = nil) {
        guard address != 0 else { return }
        var body = Wire.little64(me) + Wire.ipv4(address)
        for (ip, id) in routes.sorted(by: { $0.key < $1.key }) { body += Wire.little64(id) + Wire.ipv4(ip) }
        send(.routes, body, to: peer)
    }
    private func probe() {
        address = 0
        candidate = Wire.candidate(node: node, offset: offset)
        while routes[candidate] != nil { candidate = candidate == 0x0aff_fffe ? 0x0a00_0001 : candidate + 1 }
        conflicts.removeAll()
        deadline = now + 0.5
        send(.probe, Wire.control(ip: candidate, node: node))
    }
    private func reselect() {
        offset &+= 1
        probe()
    }

    private func settle() throws {
        let ms = UInt64(now * 1000)
        let live = conflicts.filter { ms < $0.value.milliseconds || ms - $0.value.milliseconds < 180_000 }
        if live.values.contains(where: { !$0.node.lexicographicallyPrecedes(node) }) {
            reselect()
            return
        }
        for peer in live.keys { send(.release, Wire.control(ip: candidate, node: node), to: peer) }
        var error = [CChar](repeating: 0, count: 512)
        guard sdk.api.configureTun(device, Wire.ipString(candidate), &error, 512) else {
            throw AppFailure(String(cString: error))
        }
        address = candidate
        heartbeat = now
        advertise()
    }

    private func broadcast(_ ip: UInt32) -> Bool {
        ip == UInt32.max || ip == 0x0aff_ffff || (ip >> 28) == 14
    }
    private func valid(_ ip: UInt32) -> Bool { ip > 0x0a00_0000 && ip < 0x0aff_ffff }

    private func receive(_ type: Wire.VPN, _ body: Data, peer: UInt64) {
        seen[peer] = now
        switch type {
        case .hello:
            if body.isEmpty { advertise(to: peer) }
        case .routes:
            for i in stride(from: 0, to: body.count - body.count % 12, by: 12) {
                let id = Wire.read64(body, at: i)
                let ip = Wire.readIP(body, at: i + 8)
                if peers.contains(id), valid(ip), ip != address, routes[ip] == nil { routes[ip] = id }
            }
        case .ip:
            guard address != 0, body.count >= 56 else { return }
            let packet = Data(body.dropFirst(36))
            guard packet.first.map({ $0 >> 4 }) == 4 else { return }
            let destination = Wire.readIP(packet, at: 16)
            let source = Wire.readIP(body, at: 32)
            guard valid(source), Wire.readIP(packet, at: 12) == source else { return }
            let sender = Data(body.prefix(32))
            if let recorded = routes[source], Wire.node(recorded) != sender {
                let winner = maxNode(Wire.node(recorded), sender)
                send(.release, Wire.control(ip: source, node: winner), to: winner == sender ? recorded : peer)
            }
            if destination == address || broadcast(destination) {
                write(packet)
            } else if let next = routes[destination], next != peer {
                send(.ip, body, to: next)
            }
        case .heartbeatAck: break  // Reserved by 1.6.0.
        case .probe, .conflict, .announce, .release, .heartbeat:
            guard body.count == ((type == .conflict || type == .heartbeat) ? 44 : 36) else { return }
            let ip = Wire.readIP(body)
            let remote = Data(body.dropFirst(4).prefix(32))
            guard valid(ip) else { return }
            if type != .release, remote != Wire.node(peer) { return }
            let remoteWins = node.lexicographicallyPrecedes(remote)
            switch type {
            case .probe:
                if address == ip || (address == 0 && candidate == ip) {
                    if address == 0 && remoteWins {
                        reselect()
                    } else {
                        send(.conflict, Wire.control(ip: ip, node: node, timestamp: UInt64(now * 1000)), to: peer)
                    }
                }
            case .conflict:
                if address == 0 && ip == candidate { conflicts[peer] = (remote, Wire.read64(body, at: 36)) }
            case .release:
                if remoteWins && (ip == address || (address == 0 && ip == candidate)) { reselect() }
            case .announce, .heartbeat:
                if ip == address {
                    if remoteWins {
                        reselect()
                    } else {
                        send(.release, Wire.control(ip: ip, node: node), to: peer)
                        return
                    }
                }
                let changed = routes[ip] != peer
                if changed {
                    routes = routes.filter { $0.value != peer }
                    routes[ip] = peer
                    if type == .announce { sendRoutes() }
                }
            default: break
            }
        }
    }

    private func maxNode(_ a: Data, _ b: Data) -> Data { a.lexicographicallyPrecedes(b) ? b : a }
    private func write(_ packet: Data) {
        let datagram = Wire.ipv4(UInt32(AF_INET)) + packet
        _ = datagram.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }
    func tick() throws {
        for (peer, bytes) in sdk.packets() where peers.contains(peer) {
            if let (type, body) = Wire.decodeVPN(bytes) { receive(type, body, peer: peer) }
        }
        if address == 0, now >= deadline { try settle() }
        guard address != 0 else { return }
        if now - heartbeat >= 60 {
            heartbeat = now
            send(.heartbeat, Wire.control(ip: address, node: node, timestamp: UInt64(now * 1000)))
            for (peer, last) in seen where now - last >= 360 { routes = routes.filter { $0.value != peer } }
        }
        for _ in 0..<64 {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if n < 0 && (errno == EAGAIN || errno == EINTR) { break }
            guard n > 0 else { throw AppFailure("虚拟网卡已断开 / TUN disconnected") }
            guard n >= 24, buffer[3] == UInt8(AF_INET), buffer[4] >> 4 == 4 else { continue }
            let packet = Data(buffer[4..<n])
            let dest = Wire.readIP(packet, at: 16)
            let body = node + packet.subdata(in: 12..<16) + packet
            if dest == address {
                write(packet)
            } else if broadcast(dest) {
                send(.ip, body)
            } else if let peer = routes[dest] {
                send(.ip, body, to: peer)
            }
        }
    }
}
