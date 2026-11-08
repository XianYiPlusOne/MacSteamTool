import SwiftUI
import FluentCore

struct SteamCompatibilityPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var appID = ""
    @ViewState<String> private var tool = ""
    @ViewState<[SteamCompatibility.Tool]> private var tools = []
    @ViewState<String> private var current = ""
    var body: some View {
        Panel {
            Text(model.tr("新入库游戏自动选择运行器", "Automatic runtime for imported games")).font(.headline)
            Text(model.tr("已启用：只有 Windows 可用内容时，自动选择已安装的 NotProton。保留已有逐游戏设置和可用 macOS 内容。Steam 运行时先排队，退出后自动备份应用；从本应用启动或重启 Steam 时也会先处理。", "Enabled: Windows-only content uses an installed NotProton runtime automatically. Existing per-game settings and available macOS content are preserved. Changes queue while Steam runs and apply with a backup after it exits, including before launch or restart from this app.")).font(.caption).foregroundStyle(.secondary)
            if !model.automaticCompatibilityStatus.isEmpty { Text(model.automaticCompatibilityStatus).font(.caption).textSelection(.enabled) }
            Button(model.tr("重新检查待处理游戏", "Retry pending games")) { model.reconcileAutomaticCompatibility(force: true) }.disabled(model.busy || model.automaticCompatibilityTask != nil)
            Divider()
            Text(model.tr("按 AppID 选择 Windows 运行器", "Choose a Windows runtime by AppID")).font(.headline)
            Text(model.tr("适用于库中尚未显示的游戏，或标记支持 macOS 却使用 Windows EXE 的游戏。只修改这个 AppID；先退出 Steam，保存后重新启动。", "For games not yet visible in the library, or games marked for macOS that use a Windows EXE. Changes only this AppID. Quit Steam before saving and restart afterwards.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("AppID", text: $appID).textFieldStyle(.roundedBorder).frame(width: 130).onChange(of: appID) { _, _ in readCurrent() }
                Picker(model.tr("运行方式", "Runtime"), selection: $tool) {
                    Text(model.tr("跟随 Steam 默认设置", "Follow Steam defaults")).tag("")
                    ForEach(tools) { Text($0.name).tag($0.id) }
                }
                Button(model.tr("备份并保存", "Back up & save")) {
                    guard let id = TextUtil.validID(appID) else { return }
                    let selected = tool.isEmpty ? nil : tool
                    model.run(model.tr("保存 Steam Play 设置", "Save Steam Play settings")) {
                        _ = try SteamCompatibility.save(paths: model.paths, appID: id, tool: selected)
                        model.needsRestart = true; readCurrent(); model.refresh()
                    }
                }.disabled(model.busy || model.steamRunning || TextUtil.validID(appID) == nil)
            }
            Text(model.tr("手动保存优先，包括“跟随 Steam 默认设置”；以后重新导入也不会自动覆盖。", "Manual choices take priority, including Steam defaults; reimporting will not override them.")).font(.caption).foregroundStyle(.secondary)
            if !current.isEmpty { Text(current).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(model.tr("重新读取", "Reload"), action: reload)
                Button(model.tr("打开配置备份", "Open configuration backups")) { model.openFolder(model.paths.data.appendingPathComponent("CompatibilityBackups")) }
            }
        }.onAppear(perform: reload)
    }
    private func reload() {
        do { tools = try SteamCompatibility.tools(paths: model.paths); readCurrent() } catch { model.fail(error) }
    }
    private func readCurrent() {
        guard let id = TextUtil.validID(appID) else { current = ""; return }
        do {
            let value = try SteamCompatibility.mapping(FileStore.read(model.paths.steam.appendingPathComponent("config/config.vdf")), appID: id)?.string("name")
            tool = tools.contains(where: { $0.id == value }) ? value! : ""
            current = model.tr("当前：", "Current: ") + (value ?? model.tr("跟随 Steam 默认设置", "Follow Steam defaults"))
        } catch { current = error.localizedDescription }
    }
}
