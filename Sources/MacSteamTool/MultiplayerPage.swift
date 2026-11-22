import SwiftUI
import AppKit
import MacSteamToolCore

struct MultiplayerPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ConnectToolPage(client: model.multiplayer) }
}
private struct ConnectToolPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    @ViewState<String> private var section = "room"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: model.tr("联机", "Multiplayer"), subtitle: model.tr("通过 Steam 网络与 Windows connecttool-qt 玩家连接。", "Connect with Windows connecttool-qt players through Steam networking.")) {
                MultiplayerServiceToggle(client: client)
            }
            HStack {
                Circle().fill(client.state.steamReady == true ? Palette.green : Palette.amber).frame(width: 8, height: 8)
                Text(client.statusText(model))
                Spacer()
                if let id = client.state.selfSteamId, !id.isEmpty { Text("SteamID \(id)").font(.caption.monospaced()).textSelection(.enabled) }
            }.font(.callout)
            MultiplayerSteamPrompt(client: client)
            MultiplayerFailureNotice(client: client)
            Picker("", selection: $section) {
                Text(model.tr("房间", "Room")).tag("room")
                Text(model.tr("公开大厅", "Lobbies")).tag("lobbies")
                Text(model.tr("网络状态", "Network")).tag("network")
                Text(model.tr("协议说明", "About")).tag("about")
            }.pickerStyle(.segmented).labelsHidden()
            switch section {
            case "lobbies": ConnectLobbies(client: client)
            case "network": ConnectNetwork(client: client)
            case "about": ConnectAbout(client: client)
            default:
                ConnectSession(client: client)
                HStack(alignment: .top, spacing: 18) {
                    ConnectChatPanel(client: client).frame(maxWidth: .infinity)
                    ConnectPeople(client: client).frame(width: 320)
                }
            }
        }
    }
}
private struct ConnectSession: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    var body: some View {
        Panel {
            HStack {
                Picker(model.tr("联机模式", "Mode"), selection: $client.mode) {
                    Text(model.tr("TCP 转发", "TCP forwarding")).tag(0)
                    Text(model.tr("TUN 虚拟局域网", "TUN virtual LAN")).tag(1)
                }.frame(width: 260).disabled(client.state.active || client.starting)
                Spacer()
                if client.state.active || client.starting {
                    Button(model.tr("断开连接", "Disconnect")) { client.disconnect() }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.tr("创建房间", "Create room")) { client.connect(host: true) }.disabled(client.state.steamReady != true)
                    Button(model.tr("加入房间", "Join room")) { client.connect(host: false) }.buttonStyle(.borderedProminent).disabled(client.state.steamReady != true || client.target.isEmpty)
                }
            }
            HStack {
                TextField(model.tr("房间 ID 或房主 SteamID64", "Room ID or host SteamID64"), text: $client.target).textFieldStyle(.roundedBorder)
                TextField(model.tr("创建房间的名称", "Name for your room"), text: $client.roomName).textFieldStyle(.roundedBorder)
                Toggle(model.tr("公开房间", "Public room"), isOn: $client.published)
            }.disabled(client.state.active || client.starting)
            if client.mode == 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.tr("房主游戏端口", "Host game port")).font(.caption).foregroundStyle(.secondary)
                        TextField("25565", text: $client.port).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.tr("本地监听端口", "Local listening port")).font(.caption).foregroundStyle(.secondary)
                        TextField("8888", text: $client.bindPort).textFieldStyle(.roundedBorder)
                    }
                    Text(model.tr("加入后连接 localhost:", "After joining, connect to localhost:") + (client.state.active ? String(client.state.localBindPort ?? 8888) : client.bindPort)).font(.caption).textSelection(.enabled)
                }.disabled(client.state.active || client.starting)
            } else if client.running {
                ConnectTunSetup(setup: client.tun, active: client.state.active)
                if let ip = client.state.tunLocalIp, !ip.isEmpty { CopyValue(title: model.tr("本机 IP", "Local IP"), value: ip) }
            }
            if client.state.active {
                Divider()
                HStack {
                    VStack(alignment: .leading) { Text(client.state.lobbyName ?? "").font(.headline); Text(client.state.isHost == true ? model.tr("你是房主", "You are hosting") : model.tr("已加入房间", "Joined room")).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    CopyValue(title: model.tr("房间 ID", "Room ID"), value: client.state.lobbyId ?? "")
                    CopyValue(title: model.tr("房主", "Host"), value: client.state.hostSteamId ?? "")
                }
            }
        }
    }
}
private struct ConnectTunSetup: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var setup: TunHelperController
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.tr("macOS 自带虚拟网卡，无需下载驱动。首次启用需要授权安装网络助手。", "macOS includes the virtual network interface. Authorize the helper once; no driver download is needed.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                if setup.busy { ProgressView().controlSize(.small) }
                Image(systemName: setup.ready ? "checkmark.circle.fill" : "network").foregroundStyle(setup.ready ? Palette.green : Palette.amber)
                Text(setup.message).font(.caption).textSelection(.enabled)
                Spacer()
                Button(model.tr("重新检测", "Check again")) { Task { await setup.check() } }.disabled(setup.busy || active)
                Button(model.tr(setup.ready ? "修复助手…" : "启用 / 修复虚拟网卡…", setup.ready ? "Repair helper…" : "Enable / repair virtual network…")) { Task { await setup.repair() } }.disabled(setup.busy || active)
            }
            if !setup.detail.isEmpty { Text(setup.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
        }.task { if !model.testing && !setup.checked { await setup.check() } }
    }
}
struct CopyValue: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let value: String
    var buttonTitle: String? = nil
    @ViewState private var copied = false

    func copy(to pasteboard: NSPasteboard) -> Bool {
        guard !value.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    var body: some View {
        HStack(spacing: buttonTitle == nil ? 6 : 14) {
            VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? "—" : value).font(.caption.monospaced()).textSelection(.enabled) }
            let label = copied ? model.tr("已复制", "Copied") : (buttonTitle ?? model.tr("复制", "Copy"))
            let button = Button {
                copied = copy(to: .general)
            } label: {
                Label(label, systemImage: copied ? "checkmark" : "doc.on.doc")
            }.disabled(value.isEmpty).help(label)
                .accessibilityLabel(copied ? label : model.tr("复制\(title)", "Copy \(title)"))
            if buttonTitle != nil {
                button.buttonStyle(.bordered).controlSize(.small)
            } else {
                button.labelStyle(.iconOnly).buttonStyle(.plain)
            }
        }
        .onChange(of: value) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}
private struct ConnectChatPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    var body: some View {
        Panel {
            HStack { Text(model.tr("房间聊天", "Room chat")).font(.headline); Spacer(); Toggle(model.tr("消息提醒", "Reminders"), isOn: $client.reminders).font(.caption) }
            if let pin = client.state.pinned, let text = pin.message, !text.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "pin.fill").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading) { Text(pin.displayName ?? "").font(.caption.bold()); Text(text).font(.callout).textSelection(.enabled) }
                    Spacer()
                    if client.state.isHost == true { Button(model.tr("取消置顶", "Unpin")) { client.clearPin() }.font(.caption) }
                }.padding(10).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if (client.state.messages ?? []).isEmpty { Text(model.tr("加入房间后，在这里与成员交流。", "Join a room to chat with its members.")).foregroundStyle(.secondary).padding(.vertical, 20) }
                        ForEach(client.state.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(message.displayName ?? "").font(.caption.bold()); if message.isSelf == true { Text(model.tr("自己", "You")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(message.timestamp.map { String($0.prefix(19).suffix(8)) } ?? "").font(.caption2).foregroundStyle(.secondary) }
                                Text(message.message ?? "").textSelection(.enabled).font(.callout)
                            }.id(message.id).contextMenu {
                                Button(model.tr("复制消息", "Copy message")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.message ?? "", forType: .string) }
                                if client.state.isHost == true { Button(model.tr("置顶消息", "Pin message")) { client.pin(message) } }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 300)
                .onChange(of: client.state.messages?.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            HStack {
                TextField(model.tr("输入消息…", "Message…"), text: $client.draft).textFieldStyle(.roundedBorder).onSubmit { client.sendChat() }
                Button(model.tr("发送", "Send")) { client.sendChat() }.disabled(client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled((client.state.lobbyId ?? "").isEmpty)
        }
    }
}
private struct ConnectPeople: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    @ViewState<Bool> private var friends = false
    var body: some View {
        Panel {
            Picker("", selection: $friends) {
                Text(model.tr("房间成员", "Members")).tag(false)
                Text(model.tr("Steam 好友", "Friends")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            HStack {
                if friends { TextField(model.tr("搜索好友", "Find friends"), text: $client.friendFilter).textFieldStyle(.roundedBorder).onChange(of: client.friendFilter) { _, _ in client.refreshFriends() } }
                Spacer(); Button { if friends { client.refreshFriends() } else { client.refreshMembers() } } label: { Image(systemName: "arrow.clockwise") }.disabled(!client.running)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let people = friends ? client.state.friends ?? [] : client.state.members ?? []
                    if people.isEmpty { Text(model.tr("暂无成员", "No members")).foregroundStyle(.secondary) }
                    ForEach(people) { person in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ConnectAvatar(value: person.avatar)
                                VStack(alignment: .leading) {
                                    Text(person.displayName).font(.callout.bold()).lineLimit(1)
                                    Text(person.status ?? (person.isSelf == true ? model.tr("自己", "You") : person.steamId == client.state.hostSteamId ? model.tr("房主", "Host") : model.tr("成员", "Member"))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if friends {
                                    Button((person.inviteCooldown ?? 0) > 0 ? "\(person.inviteCooldown!)s" : model.tr("邀请", "Invite")) { client.invite(person.steamId) }.disabled((client.state.lobbyId ?? "").isEmpty || (person.inviteCooldown ?? 0) > 0)
                                } else if person.isFriend != true && person.isSelf != true,
                                          let steamID = UInt64(person.steamId),
                                          let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)/") {
                                    Link(destination: url) {
                                        Label(model.tr("添加好友", "Add friend"), systemImage: "person.badge.plus").labelStyle(.iconOnly)
                                    }.help(model.tr("添加好友", "Add friend"))
                                }
                            }
                            Text(person.steamId).font(.caption2.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                            if let ip = person.ip, !ip.isEmpty { CopyValue(title: "IP", value: ip) }
                            if let ping = person.ping { Text((ping >= 0 ? "\(ping) ms" : "—") + "  " + (person.relay ?? "")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 330)
        }
    }
}
private struct ConnectAvatar: View {
    let value: String?
    var body: some View {
        Group {
            if let value, let comma = value.firstIndex(of: ","), value.hasPrefix("data:image/"), let bytes = Data(base64Encoded: String(value[value.index(after: comma)...])), let image = NSImage(data: bytes) {
                Image(nsImage: image).resizable()
            } else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
        }.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
private struct ConnectLobbies: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    private func filter() { client.filterLobbies() }
    var body: some View {
        Panel {
            HStack {
                TextField(model.tr("搜索房间或房主", "Find room or host"), text: $client.lobbyFilter).textFieldStyle(.roundedBorder).onChange(of: client.lobbyFilter) { _, _ in filter() }
                Picker(model.tr("排序", "Sort"), selection: $client.lobbySort) {
                    Text(model.tr("人数", "Members")).tag(0); Text(model.tr("名称", "Name")).tag(1); Text(model.tr("延迟", "Latency")).tag(2)
                }.frame(width: 180).onChange(of: client.lobbySort) { _, _ in filter() }
                Button(client.state.lobbyRefreshing == true ? model.tr("刷新中…", "Refreshing…") : model.tr("刷新大厅", "Refresh lobbies")) { client.refreshLobbies() }.disabled(client.state.steamReady != true || client.state.lobbyRefreshing == true)
            }
            if (client.state.lobbies ?? []).isEmpty { Text(model.tr("未找到公开房间。私有房间请通过房间 ID 或邀请加入。", "No public rooms found. Join private rooms by ID or invitation.")).foregroundStyle(.secondary).padding(.vertical, 24) }
            ForEach(client.state.lobbies ?? []) { room in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(room.name).font(.headline); Text(room.hostName + " · " + room.lobbyId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Spacer(); Text("\(room.members) " + model.tr("人", "members")).font(.caption)
                    Text(room.ping >= 0 ? "\(room.ping) ms" : "—").font(.caption).frame(width: 75)
                    Button(model.tr("加入", "Join")) { client.target = room.lobbyId; client.connect(host: false) }.disabled(client.state.active || client.starting)
                }.padding(.vertical, 8)
            }
        }.onAppear { if client.state.steamReady == true { client.refreshLobbies() } }
    }
}
private struct ConnectNetwork: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    var body: some View {
        Panel {
            Text(model.tr("连接状态", "Connection status")).font(.headline)
            LabeledContent("Steam", value: client.state.steamReady == true ? model.tr("已连接", "Connected") : model.tr("未连接", "Disconnected"))
            LabeledContent(model.tr("当前模式", "Current mode"), value: client.state.connectionMode == 1 ? "TUN" : "TCP")
            LabeledContent(model.tr("最优中继延迟", "Best relay latency"), value: (client.state.relayPing ?? -1) >= 0 ? "\(client.state.relayPing!) ms" : "—")
            LabeledContent(model.tr("TCP 连接数", "TCP clients"), value: String(client.state.tcpClients ?? 0))
            LabeledContent(model.tr("虚拟网卡", "TUN interface"), value: client.state.tunDeviceName ?? "—")
            CopyValue(title: model.tr("虚拟 IP", "Virtual IP"), value: client.state.tunLocalIp ?? "")
            Divider(); Text(model.tr("Steam 中继节点", "Steam relay locations")).font(.headline)
            if (client.state.relayPops ?? []).isEmpty { Text(model.tr("等待 Steam 网络测量…", "Waiting for Steam network measurements…")).foregroundStyle(.secondary) }
            ForEach(client.state.relayPops ?? []) { pop in
                HStack { Text(pop.name).font(.system(.body, design: .monospaced)); Spacer(); if let via = pop.via { Text("via " + via).foregroundStyle(.secondary) }; Text(pop.ping >= 0 ? "\(pop.ping) ms" : "—").frame(width: 85, alignment: .trailing) }
            }
        }
    }
}
private struct ConnectAbout: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController
    var body: some View {
        Panel {
            Text("ConnectTool 1.6.0 · Steamworks").font(.headline)
            Text(model.tr("房间、聊天与网络服务直接集成在本页。Windows 玩家使用 connecttool-qt，双方登录 Steam 后使用同一种模式加入房间。", "Rooms, chat and networking are integrated into this page. Windows players use connecttool-qt. Sign into Steam and join a room using the same mode."))
            Text(model.tr("TCP：房主填写游戏监听端口，加入方连接本地映射端口。TUN：在游戏中连接房主的虚拟 IP。游戏版本及跨平台局域网/直连支持须相互兼容。", "TCP: the host enters the game port, and guests connect to the local forwarded port. TUN: connect to the host's virtual IP in the game. Game versions and cross-platform LAN/direct connection support must be compatible."))
            Text(model.tr("切换页面或关闭主窗口后仍会保持连接，退出本程序后断开。首次配置 TUN 需要管理员授权。", "Connections stay active across page changes and when the window closes. Quitting disconnects. Initial TUN setup requires administrator authorization.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Link(model.tr("Windows 下载 / 项目说明", "Windows download / project"), destination: URL(string: "https://github.com/moeleak/connecttool-qt/releases/tag/v1.6.0")!)
            }
        }
    }
}
