import SwiftUI
import AppKit
import FluentCore

struct OnlineFixModePanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<RuntimeFeatureStatus?> private var status = nil
    var body: some View {
        Panel {
            Text(model.tr("原版内置联机模式", "Built-in multiplayer mode")).font(.headline)
            Text(model.tr("在 Steam 游戏属性的启动选项中添加 -onlinefix 即可启用；删除参数即恢复普通启动。仅对本应用已启用的主游戏生效，不替换游戏文件。", "Add -onlinefix to the game's Steam launch options to enable; remove it for normal launches. Applies only to enabled base games managed by this app, without replacing game files.")).font(.caption)
            HStack {
                Text("-onlinefix").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button(model.tr("复制参数", "Copy option")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("-onlinefix", forType: .string) }
                Spacer()
                Button(model.tr("刷新模块状态", "Refresh module status")) { status = RuntimeFeatureStatus.current(paths: model.paths) }
            }
            Text(model.tr("此模式沿用原版的 480 大厅身份，保留真实游戏的界面标识。仅适用于支持此方式的大厅游戏；双方需使用同一模式，同时只运行一款。不会自动为任何游戏开启。", "Uses the original mode's 480 lobby identity while retaining the real game's interface identity. Both players need the same mode and a compatible lobby game. Run one game at a time. Never enabled automatically.")).font(.caption).foregroundStyle(.secondary)
            if status?.onlineFix == true {
                Text((status?.onlineFixAppID ?? 0) > 0 ? model.tr("当前已启用：AppID \(status!.onlineFixAppID!)", "Active: AppID \(status!.onlineFixAppID!)") : model.tr("模块已就绪；等待带参数启动游戏", "Module ready; waiting for an explicit launch option")).font(.caption).foregroundStyle(Palette.green)
            } else {
                Text(model.tr("当前 Steam 会话未报告此模块就绪。更新运行环境中的扩展，并在下次重启 Steam 后刷新状态。", "This Steam session has not reported the module ready. Update the extension in Runtime, then refresh after the next Steam restart.")).font(.caption).foregroundStyle(Palette.amber)
            }
        }.onAppear { status = RuntimeFeatureStatus.current(paths: model.paths) }
    }
}
