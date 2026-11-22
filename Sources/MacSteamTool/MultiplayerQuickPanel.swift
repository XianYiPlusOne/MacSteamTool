import SwiftUI
import MacSteamToolCore

extension MultiplayerController {
    func statusText(_ model: AppModel) -> String {
        if starting { return model.tr("正在进入房间…", "Opening room…") }
        guard running else { return model.tr("已关闭", "Off") }
        guard state.steamReady == true else { return model.tr("等待 Steam 登录…", "Waiting for Steam sign-in…") }
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
                if enabled { client.start(steamRunning: model.steamRunning) } else { client.stop() }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityIdentifier("multiplayer-service-toggle")
    }
}

struct MultiplayerSteamPrompt: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: MultiplayerController

    var body: some View {
        if !client.running {
            Text(model.tr("开启联机将自动打开 Steam，请先登录 Steam 账号。", "Turning on multiplayer opens Steam. Sign in to your Steam account to connect."))
                .font(.caption).foregroundStyle(.secondary)
        } else if client.state.steamReady != true {
            HStack {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.tr("请在 Steam 中登录账号，应用会每 3 秒自动检测连接。", "Sign in to Steam. The app checks the connection every 3 seconds."))
                        .help(client.state.status ?? "")
                    if let error = client.steamLaunchError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Spacer()
                Button(model.tr("打开 Steam", "Open Steam")) { client.requestSteamLaunch() }
            }.font(.callout)
        }
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
            MultiplayerSteamPrompt(client: client)
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
                if let mode = state.connectionMode { Text(mode == 1 ? "TUN" : "TCP") }
                Spacer()
                if let members = state.members {
                    Label(model.tr("房间人数 \(members.count) 人", "Members: \(members.count)"), systemImage: "person.2")
                        .font(.callout.weight(.medium)).monospacedDigit()
                }
            }.font(.caption)
            if let id = state.lobbyId, !id.isEmpty {
                CopyValue(title: model.tr("房间 ID", "Room ID"), value: id,
                          buttonTitle: model.tr("复制房间 ID", "Copy room ID"))
            } else if let host = state.hostSteamId, !host.isEmpty {
                CopyValue(title: model.tr("直连房主 Steam ID", "Direct host Steam ID"), value: host,
                          buttonTitle: model.tr("复制 Steam ID", "Copy Steam ID"))
            }
            if let address = state.gameAddress {
                let title = state.connectionMode == 1 ? model.tr("房主虚拟 IP", "Host virtual IP") : model.tr("本机游戏地址", "Local game address")
                CopyValue(title: title, value: address)
            }
        }
    }
}
