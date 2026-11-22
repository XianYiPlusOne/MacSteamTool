import SwiftUI

struct GettingStartedPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: model.tr("欢迎使用 MacSteamTool", "Welcome to MacSteamTool"),
                       subtitle: model.tr("在这里准备 Steam、管理游戏，也可以和好友一起玩。", "Set up Steam, manage your games, and play with friends.")) {
                Button(model.tr("进入游戏库", "Go to library")) { model.page = .library }
            }
            RuntimeSetupPanel(flow: model.runtimePreparation)
            Panel {
                guideLink(.runtime, title: model.tr("准备玩 Windows 游戏？", "Playing a Windows game?"),
                          detail: model.tr("在「游戏兼容层」选择 Wine 并点「使用 Wine」。如果已购买并激活 CrossOver，可以选择它的应用位置，再点「使用 CrossOver」。", "Under Game translation backends, select Wine and click Use Wine. If you own an activated copy of CrossOver, select its app and click Use CrossOver."))
                Divider()
                guideLink(.library, title: model.tr("找到并启动游戏", "Find and launch a game"),
                          detail: model.tr("在游戏库按名称或 AppID 查找游戏，打开详情即可查看安装状态或启动游戏。有本地清单时，可以点「导入清单」。", "Search your library by name or AppID. Open a game to check its installation or launch it. To add a local manifest, choose Import manifests."))
                Divider()
                guideLink(.multiplayer, title: model.tr("和好友联机", "Play with friends"),
                          detail: model.tr("双方先登录 Steam，在「联机」打开服务并选择相同的联机模式。一人创建房间，把房间 ID 发给好友，另一人输入 ID 加入。", "Both players sign in to Steam, turn on Multiplayer service, and choose the same mode. One player creates a room and shares its ID. The other enters the ID to join."))
            }
        }
        .onAppear { model.markGuideSeen() }
    }

    private func guideLink(_ page: Page, title: String, detail: String) -> some View {
        Button { model.page = page } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: page.icon).font(.title3).foregroundStyle(Palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text(model.title(page))
                    Image(systemName: "chevron.right")
                }.font(.caption).foregroundStyle(Palette.accent).fixedSize()
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
