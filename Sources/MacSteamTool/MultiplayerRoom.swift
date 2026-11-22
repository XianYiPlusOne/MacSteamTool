import AppKit
import MacSteamToolCore

extension MultiplayerController {
    func sendChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdk, lobby != 0, !text.isEmpty else { return }
        guard !text.utf8.contains(0), text.utf8.count <= 2047 else {
            failure = "消息超出 1.6.0 接收上限 / Message exceeds the 2047-byte receiver limit"
            return
        }
        let sent = Data(text.utf8).withUnsafeBytes { sdk.api.chat(lobby, $0.baseAddress, Int32($0.count)) }
        if sent { draft = "" } else { failure = "消息发送失败 / Chat send failed" }
    }

    func receiveChat(_ bytes: Data, from sender: UInt64) {
        guard let sdk else { return }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        if text.hasPrefix("PING|") {
            guard sender == hostID else { return }
            for entry in text.dropFirst(5).split(separator: ";") {
                let fields = entry.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if fields.count == 3, let id = UInt64(fields[0]), let ping = Int(fields[1]), ping >= 0 {
                    pings[id] = (ping, String(fields[2]))
                }
            }
            return
        }
        var item = ConnectChat()
        item.message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.message?.isEmpty == false else { return }
        item.timestamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        item.steamId = String(sender)
        item.displayName = sdk.name(sender)
        item.isSelf = sender == me
        var messages = state.messages ?? []
        item.row = (messages.last?.row ?? -1) + 1
        messages.append(item)
        state.messages = Array(messages.suffix(500))
        if reminders && sender != me && NSApp?.isActive == false {
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
    func pin(_ message: ConnectChat) {
        guard let sdk, state.isHost == true, lobby != 0,
            state.messages?.contains(where: { $0.id == message.id }) == true,
            let id = message.steamId, let name = message.displayName, let body = message.message,
            let time = message.timestamp,
            let bytes = try? JSONEncoder().encode([
                "steamId": id, "displayName": name, "message": body, "timestamp": time,
            ])
        else { return }
        if sdk.api.setMetadata(lobby, "ct_pin", String(decoding: bytes, as: UTF8.self)) {
            refreshPin()
        } else {
            failure = "置顶失败 / Pin failed"
        }
    }
    func clearPin() {
        if let sdk, state.isHost == true, lobby != 0, sdk.api.setMetadata(lobby, "ct_pin", nil) {
            state.pinned = nil
        }
    }
    func refreshPin() {
        guard let sdk else { return }
        let bytes = Data(sdk.metadata(lobby, "ct_pin").utf8)
        state.pinned = try? JSONDecoder().decode(ConnectChat.self, from: bytes)
    }
    func invite(_ id: String) {
        guard let sdk, lobby != 0, let peer = UInt64(id), (cooldown[peer] ?? 0) <= now else { return }
        if sdk.api.invite(lobby, peer) {
            cooldown[peer] = now + 3
            refreshFriends()
        } else {
            failure = "邀请失败 / Invite failed"
        }
    }
    private func person(_ id: UInt64, sdk: MultiplayerSDK) -> ConnectPerson {
        var person = ConnectPerson(id: id, name: sdk.name(id))
        person.isSelf = id == me
        person.isFriend = sdk.api.isFriend(id)
        if avatars[id] == nil {
            var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let width = Int(sdk.api.avatar(id, &rgba, Int32(rgba.count)))
            if width > 0,
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bitmapFormat: .alphaNonpremultiplied, bytesPerRow: width * 4, bitsPerPixel: 32),
                let dest = bitmap.bitmapData
            {
                rgba.withUnsafeBufferPointer { dest.update(from: $0.baseAddress!, count: width * width * 4) }
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    avatars[id] = "data:image/png;base64," + png.base64EncodedString()
                }
            }
        }
        person.avatar = avatars[id]
        return person
    }
    func refreshFriends() {
        guard let sdk, me != 0 else { return }
        cooldown = cooldown.filter { $0.value > now }
        var people = [ConnectPerson]()
        for i in 0..<max(0, sdk.api.friendCount()) {
            let id = sdk.api.friendAt(i)
            var friend = person(id, sdk: sdk)
            friend.online = sdk.api.personaState(id) != 0
            friend.status = friend.online == true ? "在线 / Online" : "离线 / Offline"
            friend.inviteCooldown = Int(ceil((cooldown[id] ?? now) - now))
            if friendFilter.isEmpty || friend.displayName.localizedCaseInsensitiveContains(friendFilter)
                || friend.steamId.contains(friendFilter)
            {
                people.append(friend)
            }
        }
        state.friends = people.sorted {
            if $0.online != $1.online { return $0.online == true }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
    func refreshMembers() {
        guard let sdk, me != 0, lobby != 0 || hostID != 0 else { return }
        let ids =
            lobby == 0 ? [me, hostID] : (0..<max(0, sdk.api.memberCount(lobby))).map { sdk.api.member(lobby, $0) }
        let current = Set(ids.filter { $0 != 0 })
        if let lan {
            for peer in members.subtracting(current) {
                direct.remove(peer)
                lan.remove(peer)
            }
            for peer in current where peer != me { lan.add(peer) }
        }
        members = current
        state.members = ids.filter { $0 != 0 }.map { id in
            var value = person(id, sdk: sdk)
            value.ip = lan?.peerAddress(id)
            if let (ping, route) = pings[id] {
                value.ping = ping
                value.relay = route
            }
            return value
        }
        if let lan, lan.address != 0 { state.tunLocalIp = MultiplayerWire.ipString(lan.address) }
        if let tcp {
            state.tcpClients = tcp.count
            state.isConnected = state.isHost != true && tcp.connected
        }
    }
    func refreshLobbies() {
        guard let sdk, me != 0, listCall == 0 else { return }
        listCall = sdk.api.list("ct_tag", "1")
        listStarted = now
        state.lobbyRefreshing = listCall != 0
    }
    func receiveList(_ count: Int) {
        guard let sdk, count >= 0 else { return }
        rooms = (0..<min(count, 100)).map { i in
            let room = sdk.api.listedLobby(Int32(i))
            let id = UInt64(sdk.metadata(room, "ct_host_id")) ?? sdk.api.owner(room)
            return ConnectLobby(
                id: room, name: sdk.metadata(room, "ct_name"), host: id,
                hostName: sdk.metadata(room, "ct_host_name"),
                members: Int(sdk.api.memberCount(room)),
                ping: Int(sdk.api.estimatePing(sdk.metadata(room, "ct_ping_loc"))))
        }
        filterLobbies()
    }
    func filterLobbies() {
        let filtered = rooms.filter {
            lobbyFilter.isEmpty
                || [$0.name, $0.hostName, $0.lobbyId].contains { $0.localizedCaseInsensitiveContains(lobbyFilter) }
        }
        state.lobbies = filtered.sorted {
            switch lobbySort {
            case 1: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case 2: return ($0.ping < 0 ? Int.max : $0.ping) < ($1.ping < 0 ? Int.max : $1.ping)
            default: return $0.members > $1.members
            }
        }
    }
    func refreshNetwork() {
        guard let sdk, me != 0 else { return }
        var values = [UInt32](repeating: 0, count: 256)
        let n = min(values.count, max(0, Int(sdk.api.popList(&values, Int32(values.count)))))
        func name(_ code: UInt32) -> String {
            String(
                decoding: [
                    UInt8(truncatingIfNeeded: code >> 16), UInt8(truncatingIfNeeded: code >> 8),
                    UInt8(truncatingIfNeeded: code), UInt8(truncatingIfNeeded: code >> 24),
                ].prefix { $0 != 0 }, as: UTF8.self)
        }
        state.relayPops = values.prefix(n).map {
            var via: UInt32 = 0
            let ping = sdk.api.popPing($0, &via)
            return ConnectPOP(name: name($0), ping: Int(ping), via: via == 0 || via == $0 ? nil : name(via))
        }.sorted { ($0.ping < 0 ? Int.max : $0.ping) < ($1.ping < 0 ? Int.max : $1.ping) }
        state.relayPing = state.relayPops?.first?.ping
        var measured = [UInt64: (Int, String)]()
        for (h, peer) in tcp?.peers ?? [:] {
            var relay = false
            let p = sdk.api.connectionPing(h, &relay)
            if p >= 0 { measured[peer] = (Int(p), relay ? "中继" : "P2P") }
        }
        for peer in lan?.peers ?? [] {
            var relay = false
            let p = sdk.api.vpnPing(peer, &relay)
            if p >= 0 { measured[peer] = (Int(p), relay ? "中继" : "P2P") }
        }
        pings.merge(measured) { _, new in new }
        if state.isHost == true, tcp != nil, lobby != 0, !measured.isEmpty {
            let entries = measured.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.0):\($0.value.1)" }
            let data = Data(("PING|" + entries.joined(separator: ";")).utf8)
            if data.count <= 2047 {
                _ = data.withUnsafeBytes { sdk.api.chat(lobby, $0.baseAddress, Int32($0.count)) }
            }
        }
    }
}
