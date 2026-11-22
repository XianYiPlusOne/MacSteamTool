import SwiftUI

struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var flow: RuntimePreparationController

    var body: some View {
        if flow.ready {
            MultiplayerSidebarStatus(client: model.multiplayer)
        } else {
            SidebarStatusLink(title: model.title(.runtime), icon: Page.runtime.icon,
                              status: flow.statusTitle(model), color: flow.working || flow.state == .checking ? Palette.accent : Palette.amber,
                              actionTitle: model.tr("查看安装步骤", "View setup steps")) { model.page = .runtime }
        }
    }
}

private struct MultiplayerSidebarStatus: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var client: MultiplayerController

    var body: some View {
        let failed = !client.starting && !client.running && client.failure != nil
        let connected = client.running && client.state.steamReady == true
        SidebarStatusLink(title: model.tr("联机状态", "Multiplayer status"), icon: Page.multiplayer.icon,
                          status: failed ? model.tr("联机服务异常", "Multiplayer service error") : client.statusText(model),
                          color: failed ? Palette.amber : connected ? Palette.green : .secondary,
                          detail: connected && client.state.active ? client.state.lobbyName : nil,
                          actionTitle: model.tr("打开联机", "Open multiplayer")) { model.page = .multiplayer }
    }
}

private struct SidebarStatusLink: View {
    let title: String
    let icon: String
    let status: String
    let color: Color
    var detail: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: icon).font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(status).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    Text(actionTitle)
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.caption.weight(.medium)).foregroundStyle(Palette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
