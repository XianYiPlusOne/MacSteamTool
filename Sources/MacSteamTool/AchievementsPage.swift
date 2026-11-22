import SwiftUI
import MacSteamToolCore

struct AchievementsPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var search = ""
    @ViewState<Bool> private var showPreparation = false
    @ViewState<Bool> private var showStatistics = false

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var games: [Game] {
        let term = query
        let exactID = TextUtil.validID(term)
        return model.games.filter { term.isEmpty || $0.id == exactID || $0.name.localizedCaseInsensitiveContains(term) || String($0.id).contains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: model.title(.achievements), subtitle: model.tr("选择游戏，查看已解锁的成就或编辑解锁状态。", "Choose a game to view its achievements and edit their unlock status.")) {
                Button(model.tr("统计与时长", "Statistics & playtime")) { showStatistics = true }
                    .popover(isPresented: $showStatistics) { StatisticsSettings() }
                Button { showPreparation.toggle() } label: {
                    Label(model.tr("自动准备", "Automatic preparation"), systemImage: "gearshape")
                }
                .popover(isPresented: $showPreparation) { preparationSettings }
            }
            Panel(padding: 16) {
                HStack {
                    Label(model.tr("游戏列表", "Games"), systemImage: "gamecontroller").font(.headline)
                    Spacer()
                    TextField(model.tr("搜索游戏名称或 AppID", "Search games by name or AppID"), text: $search)
                        .textFieldStyle(.roundedBorder).frame(width: 235)
                }
                Divider()
                let matches = games
                if let id = TextUtil.validID(query), !model.games.contains(where: { $0.id == id }) {
                    Button(model.tr("按 AppID \(id) 打开…", "Open AppID \(id)…")) {
                        model.openAchievementEditor(for: Game(id: id, name: "App \(id)"))
                    }.disabled(model.busy)
                }
                if matches.isEmpty {
                    if TextUtil.validID(query) == nil {
                        EmptyMessage(icon: "gamecontroller", title: query.isEmpty ? model.tr("游戏库为空", "Your library is empty") : model.tr("没有匹配的游戏", "No matching games"),
                                     detail: model.tr("可输入完整 AppID 打开游戏的成就。", "Enter a full AppID to open a game's achievements."))
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { game in
                            gameRow(game)
                            if game.id != matches.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .sheet(item: $model.achievementGame) { game in
            AchievementEditorSheet(game: game)
        }
    }

    private func gameRow(_ game: Game) -> some View {
        HStack(spacing: 14) {
            Cover(id: game.id, name: game.name, height: 42)
                .frame(width: 84).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(game.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(game.name)
                Text("AppID \(String(game.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.achievementProgress[game.id] {
                Text(model.tr("上次读取 · 已解锁 \(progress.unlocked)/\(progress.total)", "Last read · \(progress.unlocked)/\(progress.total) unlocked"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(model.tr("管理成就…", "Manage achievements…")) { model.openAchievementEditor(for: game) }
                .disabled(model.busy)
        }.padding(.vertical, 8)
    }

    private var preparationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(onClose: { showPreparation = false }) {
                Toggle(model.tr("自动准备新入库游戏的兼容成就", "Automatically prepare achievements for newly added games"), isOn: Binding(get: {
                    model.preferences.automaticallyPrepareAchievements != false
                }, set: {
                    model.automaticAchievementsTask?.cancel()
                    model.preferences.automaticallyPrepareAchievements = $0
                    model.savePreferences()
                })).disabled(model.busy)
            }
            Text(model.tr("Steam 登录后读取成就定义，退出后备份并启用。成就仍需在游戏中获得或手动解锁。", "Fetch definitions after Steam sign-in, then back up and enable them after Steam exits. Achievements can be earned in game or unlocked manually."))
                .font(.caption).foregroundStyle(.secondary)
            if !model.automaticAchievementsStatus.isEmpty {
                Text(model.automaticAchievementsStatus).font(.caption).textSelection(.enabled)
            }
            Button(model.tr("重试成就准备", "Retry achievement preparation")) { model.reconcileAutomaticAchievements(force: true) }
                .disabled(model.busy || model.automaticAchievementsTask != nil || model.preferences.automaticallyPrepareAchievements == false)
        }.padding(18).frame(width: 360)
    }
}

private struct StatisticsSettings: View {
    @EnvironmentObject var model: AppModel
    @ViewState<StatisticsConfiguration> private var settings = .init()
    @ViewState<StatisticsConfiguration?> private var original = nil
    @ViewState<String> private var error = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(onClose: { dismiss() }) {
                Text(model.tr("统计与时长", "Statistics & playtime")).font(.headline)
            }
            TextField(model.tr("统计 AppID，用逗号分隔", "Statistics AppIDs, separated by commas"), text: $settings.statsApps)
            Toggle(model.tr("同步成就与统计", "Sync achievements and statistics"), isOn: $settings.syncAchievements)
            Toggle(model.tr("记录并同步游戏时长", "Track and sync playtime"), isOn: $settings.syncPlaytime)
            Text(model.tr("退出 Steam 后保存，下次启动 Steam 时生效。", "Quit Steam to save. Changes apply the next time Steam starts."))
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            Button(model.tr("保存统计设置", "Save statistics settings")) {
                do {
                    guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam before saving") }
                    try settings.save(paths: model.paths)
                    model.needsRestart = true
                    model.refresh()
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.disabled(model.busy || model.steamRunning || original == nil || settings == original)
        }.padding(18).frame(width: 360)
        .onAppear {
            do { settings = try StatisticsConfiguration.load(paths: model.paths); original = settings }
            catch { self.error = error.localizedDescription }
        }
    }
}
