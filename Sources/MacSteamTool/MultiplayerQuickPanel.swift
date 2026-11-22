import SwiftUI
import MacSteamToolCore

extension MultiplayerController {
    func statusText(_ model: AppModel) -> String {
        if stopping { return model.tr("正在关闭…", "Stopping…") }
        if starting { return model.tr("正在连接 Steam…", "Connecting to Steam…") }
        guard running else { return model.tr("已关闭", "Off") }
        guard state.steamReady == true else { return model.tr("Steam 未连接", "Steam disconnected") }
        guard state.active else { return model.tr("Steam 已连接 · 尚未加入房间", "Steam connected · No room joined") }
        return state.isHost == true ? model.tr("你是房主", "Hosting") : model.tr("已加入房间", "Room joined")
    }
}

struct MultiplayerServiceToggle: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController

    var body: some View {
        Toggle(model.tr("联机服务", "Multiplayer service"), isOn: Binding(
            get: { client.starting || client.running },
            set: { enabled in
                if enabled { client.start() } else { client.stop() }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(client.stopping)
        .accessibilityIdentifier("multiplayer-service-toggle")
    }
}

struct MultiplayerFailureNotice: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController

    var body: some View {
        if let failure = client.failure {
            HStack {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
                Spacer()
                Button(model.tr("关闭提示", "Dismiss")) { client.failure = nil }
            }.font(.caption)
        }
    }
}

struct MultiplayerQuickPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController

    var body: some View {
        Panel(padding: 14) {
            HStack(spacing: 12) {
                Label(model.tr("联机", "Multiplayer"), systemImage: "network").font(.headline)
                Text(client.statusText(model)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if client.running {
                    Button(model.tr("管理房间", "Manage rooms")) { model.page = .multiplayer }
                }
                MultiplayerServiceToggle(client: client)
            }
            if client.running && client.state.active {
                Divider()
                roomInfo(client.state)
            }
            MultiplayerFailureNotice(client: client)
        }
    }

    private func roomInfo(_ state: ConnectState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let name = state.lobbyName, !name.isEmpty {
                    Text(name).font(.headline).lineLimit(1).textSelection(.enabled)
                }
                if let members = state.members {
                    Label(model.tr("\(members.count) 人", "\(members.count) members"), systemImage: "person.2")
                }
                if let mode = state.connectionMode { Text(mode == 1 ? "TUN" : "TCP") }
            }.font(.caption)
            HStack(spacing: 24) {
                if let id = state.lobbyId, !id.isEmpty {
                    CopyValue(title: model.tr("房间 ID", "Room ID"), value: id)
                }
                if let address = state.gameAddress {
                    let title = state.connectionMode == 1 ? model.tr("房主虚拟 IP", "Host virtual IP") : model.tr("本机游戏地址", "Local game address")
                    CopyValue(title: title, value: address)
                }
            }
        }
    }
}
