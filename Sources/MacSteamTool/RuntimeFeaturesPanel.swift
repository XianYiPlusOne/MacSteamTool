import SwiftUI
import AppKit
import MacSteamToolCore

struct RuntimeFeaturesPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<RuntimeFeatures> private var config = .init()
    @ViewState<String> private var ids = ""
    @ViewState<String> private var status = ""
    @ViewState<RuntimeFeatureStatus?> private var runtimeStatus = nil
    var body: some View {
        Panel {
            Text(model.tr("票据消费与好友广播", "Ticket consumption and friend presence")).font(.headline)
            Text(model.tr("由原生扩展处理 macSteam 与 NotProton 游戏的 Steam 请求。扫码登录可以暂缓；本地票据来自已登录的 Steam。", "The native extension handles Steam requests from macSteam and NotProton games. Local tickets use the signed-in Steam client.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.tr("安装 / 更新原生扩展", "Install / update native extension")) { deploy() }.disabled(model.busy || model.steamRunning)
                Text(model.tr("安装前需退出 Steam；会完整备份原应用。", "Quit Steam before installing. The original app is backed up.")).font(.caption).foregroundStyle(.secondary)
            }
            if let s = runtimeStatus {
                Text("PID \(s.pid) · " + model.tr("票据 \(s.tickets ? "已挂接" : "未挂接") · 广播 \(s.presence ? "已挂接" : "未挂接") · 时长刷新 \(s.playtimeWriter ? "就绪" : "等待 Steam 用户")", "Tickets \(s.tickets ? "hooked" : "inactive") · Presence \(s.presence ? "hooked" : "inactive") · Playtime writer \(s.playtimeWriter ? "ready" : "waiting for Steam user")")).font(.caption)
                Text(model.tr("所有权票据 \(s.ownershipServed) · 加密票据 \(s.encryptedServed) · 回调 \(s.callbacksServed) · 游戏消息 \(s.gamesObserved) · 广播改写 \(s.presenceChanged)", "Ownership \(s.ownershipServed) · Encrypted \(s.encryptedServed) · Callbacks \(s.callbacksServed) · Game messages \(s.gamesObserved) · Presence changes \(s.presenceChanged)")).font(.caption).foregroundStyle(.secondary)
                if let sent = s.presenceSent, let count = s.presenceAppsLoaded {
                    Text(model.tr("生效范围 \(count) 款 · 已提交 Steam 发送队列 \(sent) 次 · 失败 \(s.presenceFailures ?? 0) 次", "Active scope: \(count) games · Submitted to Steam: \(sent) · Failed: \(s.presenceFailures ?? 0)")).font(.caption)
                    if let id = s.presenceLastAppID, id > 0, let time = s.presenceLastSentAt, time > 0 {
                        Text(model.tr("最近提交：App \(id) · ", "Last submission: App \(id) · ") + Date(timeIntervalSince1970: Double(time)).formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        if let gameID = s.presenceLastGameID {
                            Text(gameID == 0 ? model.tr("该次消息已隐藏所选游戏", "Selected game was hidden in that message") : model.tr("发送消息中的 GameID：\(gameID)", "GameID in the outgoing message: \(gameID)")).font(.caption)
                            if gameID == 480 && id != 480 { Text(model.tr("这次使用 Spacewar 身份显示游戏名，Steam 可能记录 Spacewar 时长。", "This message used Spacewar with the game title; Steam may record Spacewar playtime.")).font(.caption).foregroundStyle(Palette.amber) }
                            else if (gameID >> 24) & 0xff == 2 { Text(model.tr("这次使用非 Steam 游戏身份显示游戏名。", "This message used a non-Steam shortcut with the game title.")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text(model.tr("好友通知已通过用户实测验收。显示和弹窗仍遵循 Steam 隐私与通知设置。", "Friend notifications passed user acceptance. Display and popups follow Steam privacy and notification settings.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.tr("已加载的扩展版本较旧，需要更新扩展并重启 Steam，才能使用自动广播与发送诊断。", "Update the native extension and restart Steam to enable automatic presence and send diagnostics.")).font(.caption).foregroundStyle(Palette.amber)
                }
                if s.presenceIdentity != "shortcut-or-spacewar" {
                    Text(model.tr("当前扩展尚不支持原版的快捷方式优先广播。请退出 Steam、更新原生扩展后再启动。", "The loaded extension lacks shortcut-first compatibility presence. Quit Steam, update the extension, then relaunch.")).font(.caption).foregroundStyle(Palette.amber)
                } else if let count = s.presenceShortcutsLoaded, config.presence == .automatic || config.presence == .selected {
                    Text(count > 0 ? model.tr("当前账号可用非 Steam 快捷方式：\(count) 项", "Non-Steam shortcuts for the current account: \(count)") : model.tr("当前账号没有可用非 Steam 快捷方式，将回退为 Spacewar 身份。", "No usable non-Steam shortcut for this account; compatibility presence will use Spacewar.")).font(.caption).foregroundStyle(.secondary)
                }
            } else { Text(model.tr("当前 Steam 进程尚未加载此扩展。", "The current Steam process has not loaded this extension.")).font(.caption).foregroundStyle(Palette.amber) }
            Button(model.tr("刷新运行状态", "Refresh runtime status")) { runtimeStatus = RuntimeFeatureStatus.current(paths: model.paths) }
            Text(model.tr("Lua addtoken 会随导入、启用和禁用同步；旧 Lua 可在运行环境页同步。仅向 Steam 发送对应已启用 AppID 的访问令牌。", "Lua addtoken follows import, enable and disable. Sync older Lua files on the Runtime page. Access tokens are sent only to Steam for matching enabled AppIDs.")).font(.caption).foregroundStyle(.secondary)
            if let s = runtimeStatus, let loaded = s.accessTokensLoaded { Text(model.tr("访问令牌 \(loaded) 项 · 请求应用 \(s.accessTokenRequests ?? 0) 次", "Access tokens: \(loaded) · Applied requests: \(s.accessTokenRequests ?? 0)")).font(.caption) }
            ManifestProviderPanel()
            Divider().padding(.vertical, 5)
            Text(model.tr("好友游玩状态", "Friend game status")).font(.subheadline.bold())
            Picker(model.tr("广播方式", "Presence mode"), selection: $config.presence) {
                Text(model.tr("自动兼容广播（参照原版）", "Automatic compatibility presence")).tag(FriendPresence.automatic)
                Text(model.tr("跟随 Steam", "Follow Steam")).tag(FriendPresence.unchanged)
                Text(model.tr("兼容广播所选游戏", "Compatibility presence for selected games")).tag(FriendPresence.selected)
                Text(model.tr("隐藏所选游戏", "Hide selected games")).tag(FriendPresence.none)
            }
            if config.presence == .automatic {
                Text(model.tr("自动跟随 Lua/macSteam 启用列表，处理最近启动的游戏。优先使用当前账号已有的非 Steam 快捷方式，找不到时回退 Spacewar；发送的名称跟随本应用语言与已读取的商店资料。", "Follows enabled Lua/macSteam games and handles the most recently started game. Uses an existing non-Steam shortcut for this account first, then Spacewar if unavailable. Sent titles follow this app's language and loaded store metadata.")).font(.caption).foregroundStyle(.secondary)
            } else if config.presence != .unchanged {
                TextField(model.tr("需要控制的 AppID，逗号分隔", "Selected AppIDs, separated by commas"), text: $ids).textFieldStyle(.roundedBorder)
            }
            if config.presence == .automatic || config.presence == .selected {
                Text(model.tr("兼容广播显示游戏名，但不是正式商店 AppID；Spacewar 回退可能记录其游玩时长，通知也可能显示 Spacewar。好友端显示与通知由 Steam 处理。", "Compatibility presence shows the game title using a different identity. The Spacewar fallback may record Spacewar playtime and show Spacewar in notifications. Steam handles friend-side display and notifications.")).font(.caption).foregroundStyle(.secondary)
            }
            Button(model.tr("保存广播设置", "Save presence settings")) { savePresence() }.disabled(model.busy)
            Text(model.tr("自动广播默认开启；已保存的隐藏或跟随 Steam 设置会保留。设置在下一次游戏状态消息生效；正在运行的游戏需退出或重新启动后更新状态。", "Automatic presence is on by default; saved hidden/native settings are preserved. Changes apply on the next game-status message, normally when a game exits or starts.")).font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 5)
            HStack {
                Text(model.tr("已缓存票据", "Cached tickets")).font(.subheadline.bold()); Spacer()
                Button(model.tr("导入原版票据文本…", "Import ticket text…")) { importText() }
                Button(model.tr("导入双票据文件夹…", "Import ticket folder…")) { importFolder() }
            }.disabled(model.busy)
            if config.tickets.isEmpty { Text(model.tr("暂无票据。可在上方提取本地票据后导入。", "No tickets. Extract local tickets above, then import them.")).font(.caption).foregroundStyle(.secondary) }
            ForEach(config.tickets.keys.sorted(), id: \.self) { key in
                HStack {
                    Text("App \(key)").font(.system(.body, design: .monospaced))
                    Toggle(model.tr("启用消费", "Enable consumption"), isOn: Binding(get: { config.tickets[key]?.enabled ?? false }, set: { enabled in updateTicket(key, enabled: enabled) })).toggleStyle(.checkbox)
                    Spacer()
                    Text(model.tr("绑定票据账号", "Bound to ticket account")).font(.caption).foregroundStyle(.secondary)
                    Button(model.tr("移除", "Remove")) { updateTicket(key, enabled: nil) }
                }
            }
            Text(model.tr("票据仅保存在本机私有文件；原生扩展只在票据账号与当前账号相同时使用。票据可能过期，导入不代表受保护游戏已经验证通过。", "Tickets are stored in an owner-only local file and consumed only by the matching Steam account. Tickets can expire; importing them does not verify a protected game's launch.")).font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }.task { reload() }
    }
    private func reload() {
        do { runtimeStatus = RuntimeFeatureStatus.current(paths: model.paths); config = try RuntimeFeatures.load(paths: model.paths); ids = config.presenceApps.keys.sorted().joined(separator: ", ") }
        catch { model.fail(error) }
    }
    private func savePresence() {
        do {
            let parts = ids.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init), apps = parts.compactMap(TextUtil.validID)
            let manual = config.presence == .selected || config.presence == .none
            guard !manual || (parts.count == apps.count && !apps.isEmpty) else { throw AppFailure("请明确选择广播控制的 AppID / Select AppIDs for presence control") }
            var fresh = try RuntimeFeatures.load(paths: model.paths); fresh.presence = config.presence
            if manual { fresh.presenceApps = Dictionary(uniqueKeysWithValues: Set(apps).map { id in (String(id), model.games.first(where: { $0.id == id })?.name ?? "App \(id)") }) }
            try fresh.save(paths: model.paths); config = fresh; status = model.tr("广播设置已保存，下次游戏状态消息生效。", "Saved. Applies to the next game-status message.")
            if fresh.presence == .automatic || fresh.presence == .selected { model.refresh() }
        } catch { model.fail(error) }
    }
    private func updateTicket(_ key: String, enabled: Bool?) {
        do { var fresh = try RuntimeFeatures.load(paths: model.paths); if let enabled { fresh.tickets[key]?.enabled = enabled } else { fresh.tickets.removeValue(forKey: key) }; try fresh.save(paths: model.paths); config = fresh }
        catch { model.fail(error) }
    }
    private func store(_ ticket: CachedSteamTicket) throws {
        var fresh = try RuntimeFeatures.load(paths: model.paths); fresh.tickets[String(ticket.appID)] = ticket; try fresh.save(paths: model.paths); config = fresh
        status = model.tr("票据已导入，默认未启用；可勾选启用消费。", "Imported and disabled by default. Enable consumption when ready.")
    }
    private func importText() {
        let p = NSOpenPanel(); p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try store(CachedSteamTicket.parse(FileStore.text(url))) } catch { model.fail(error) }
    }
    private func importFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        guard p.runModal() == .OK, let folder = p.url else { return }
        do {
            let files = try FileStore.fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "appticket" }
            guard files.count == 1, let file = files.first, let id = TextUtil.validID(file.deletingPathExtension().lastPathComponent) else { throw AppFailure("请选择包含一组 AppID.appticket 与 AppID.eticket 的文件夹 / Select a folder containing one pair of AppID.appticket and AppID.eticket files") }
            try store(CachedSteamTicket(appID: id, ownership: FileStore.read(file), encrypted: FileStore.read(folder.appendingPathComponent("\(id).eticket"))))
        } catch { model.fail(error) }
    }
    private func deploy() {
        model.run(model.tr("安装原生扩展", "Install native extension"), cancellable: false) {
            let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Cloud/cloud_redirect.dylib")
            let backup = try await KernelDeployment.deploy(name: "cloud_redirect.dylib", source: library, paths: model.paths)
            model.needsRestart = true; model.refresh(); status = model.tr("安装完成，备份：", "Installed. Backup: ") + backup.path
        }
    }
}
