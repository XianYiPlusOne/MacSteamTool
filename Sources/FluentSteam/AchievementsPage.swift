import SwiftUI
import FluentCore

struct AchievementsPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var filter = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("Steam 成就管理", "Steam achievements"), subtitle: model.tr("连接当前登录的 Steam 账号，读取、编辑并提交成就状态。", "Read, edit and submit achievements for the currently signed-in Steam account.")) { EmptyView() }
            Panel {
                Label(model.tr("先选择游戏并读取当前状态；读取成功后才能编辑和保存成就。", "Choose a game and load its current state before editing or saving achievements."), systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle(model.tr("自动准备新入库游戏的兼容成就", "Automatically prepare achievements for newly added games"), isOn: Binding(get: { model.preferences.automaticallyPrepareAchievements != false }, set: {
                    model.automaticAchievementsTask?.cancel()
                    model.preferences.automaticallyPrepareAchievements = $0; model.savePreferences()
                }))
                Text(model.tr("Steam 登录后读取定义，退出后备份并启用。不会自动解锁成就，也不会批量改动已有游戏。", "Fetch definitions after Steam sign-in, then back up and enable after Steam exits. This never unlocks achievements or enrolls existing games in bulk.")).font(.caption).foregroundStyle(.secondary)
                if !model.automaticAchievementsStatus.isEmpty { Text(model.automaticAchievementsStatus).font(.caption).textSelection(.enabled) }
                Button(model.tr("重试成就准备", "Retry achievement preparation")) { model.reconcileAutomaticAchievements(force: true) }.disabled(model.busy || model.automaticAchievementsTask != nil || model.preferences.automaticallyPrepareAchievements == false)
            }
            Panel {
                HStack {
                    TextField("AppID", text: $model.achievementApp).textFieldStyle(.roundedBorder).frame(width: 145)
                    Menu(model.tr("从游戏库选择", "Choose from library")) {
                        ForEach(model.games) { game in Button(game.name) { model.achievementApp = String(game.id) } }
                    }
                    Button(model.tr("读取成就", "Load achievements")) { model.readAchievements() }.buttonStyle(.borderedProminent).disabled(model.busy || TextUtil.validID(model.achievementApp) == nil)
                    Spacer()
                    if !model.steamRunning { Button(model.tr("启动 Steam", "Launch Steam")) { model.launchSteam() } }
                }
                Text(model.tr("读取与保存会为此 AppID 建立独立 Steam 会话；已登录且拥有的游戏才能正常写回。", "Reading and saving open an isolated Steam session for this AppID. A signed-in account with access to the game is required for normal write-back.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.tr("初始化兼容成就", "Initialize compatible achievements")) { model.repairAchievements() }
                        .disabled(model.busy || !model.steamRunning || !model.games.contains(where: { $0.enabled && String($0.id) == model.achievementApp }))
                    Text(model.tr("用于已添加游戏返回 EResult=2：获取公开定义，启用所选游戏的当前账号统计；需重启 Steam。不会导入他人的解锁记录。", "For added games returning EResult=2: fetch public definitions and enable this account's statistics for the selected game; restart Steam afterward. Other users' unlocks are not imported.")).font(.caption).foregroundStyle(.secondary)
                }
                if model.loadedAchievementApp == nil && !model.achievementStatus.isEmpty { Text(model.achievementStatus).font(.caption).textSelection(.enabled) }
            }
            if let id = TextUtil.validID(model.achievementApp), let installed = model.games.first(where: { $0.id == id })?.installed { GameStartupPanel(game: installed) }
            if let id = model.loadedAchievementApp {
                Panel {
                    HStack {
                        Text("App \(String(id)) · \(model.achievements.count) " + model.tr("项成就", "achievements")).font(.headline)
                        Spacer(); Text(model.achievementStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField(model.tr("筛选成就名称 / ID", "Filter achievement name / ID"), text: $filter).textFieldStyle(.roundedBorder)
                        Menu(model.tr("批量编辑", "Bulk edit")) {
                            Button(model.tr("全部解锁", "Unlock all")) { for i in model.achievements.indices { model.achievements[i].achieved = true } }
                            Button(model.tr("全部锁定", "Lock all")) { for i in model.achievements.indices { model.achievements[i].achieved = false } }
                            Button(model.tr("反选全部", "Invert all")) { model.invertAchievements() }
                            Button(model.tr("撤销本次编辑", "Discard edits")) { model.achievements = model.originalAchievements }
                        }.disabled(model.busy)
                        Button((model.achievementBackend == "compatibility" ? model.tr("保存兼容记录", "Save compatibility record") : model.tr("保存到 Steam", "Save to Steam")) + " (\(model.achievementChanges.count))") { model.saveAchievements() }.buttonStyle(.borderedProminent).disabled(model.busy || model.achievementChanges.isEmpty || !model.steamRunning)
                    }.padding(.vertical, 8)
                    if model.achievements.isEmpty { Text(model.tr("Steam 未返回成就条目。", "Steam returned no achievements.")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.achievements.indices, id: \.self) { index in
                        let row = model.achievements[index]
                        if filter.isEmpty || row.name.localizedCaseInsensitiveContains(filter) || row.id.localizedCaseInsensitiveContains(filter) {
                            HStack(alignment: .top, spacing: 14) {
                                Toggle("", isOn: $model.achievements[index].achieved).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.name.isEmpty ? row.id : row.name).font(.system(size: 13, weight: .semibold))
                                    if !row.detail.isEmpty { Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                                    Text(row.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if row.unlockedAt > 0 { Text(Date(timeIntervalSince1970: TimeInterval(row.unlockedAt)), style: .date).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 9)
                        }
                    }
                }
            }
        }
    }
}

extension AppModel {
    func invertAchievements() { guard !busy else { return }; for index in achievements.indices { achievements[index].achieved.toggle() } }
}
