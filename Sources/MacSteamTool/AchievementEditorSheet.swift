import SwiftUI
import MacSteamToolCore

struct AchievementEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState<String> private var filter = ""
    @ViewState<Bool> private var confirmDiscard = false
    let game: Game

    private var loaded: Bool { model.loadedAchievementApp == game.id }
    private var saveTitle: String {
        model.achievementBackend == "compatibility" ? model.tr("保存兼容记录", "Save compatibility record") : model.tr("保存到 Steam", "Save to Steam")
    }
    private var matching: [Achievement] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.achievements.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let changes = model.achievementChanges.count
        VStack(spacing: 0) {
            SheetHeader(canClose: !model.busy, onClose: requestClose) {
                Image(systemName: "trophy").font(.title2).foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.name).font(.title2.bold()).lineLimit(2)
                    Text(model.tr("成就管理", "Achievements") + " · AppID \(game.id)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.steamRunning {
                    Button(loaded ? model.tr("重新读取", "Reload") : model.tr("读取成就", "Load achievements")) { model.readAchievements() }
                        .disabled(model.busy || changes > 0)
                }
            }.padding(20)
            Divider()
            if loaded && !model.achievements.isEmpty {
                HStack {
                    TextField(model.tr("筛选成就名称或 ID", "Filter achievements by name or ID"), text: $filter).textFieldStyle(.roundedBorder)
                    Menu(model.tr("批量编辑", "Bulk edit")) {
                        Button(model.tr("全部解锁", "Unlock all")) { for index in model.achievements.indices { model.achievements[index].achieved = true } }
                        Button(model.tr("全部锁定", "Lock all")) { for index in model.achievements.indices { model.achievements[index].achieved = false } }
                        Button(model.tr("反选全部", "Invert all")) { model.invertAchievements() }
                        Divider()
                        Button(model.tr("撤销本次编辑", "Discard edits")) { model.achievements = model.originalAchievements }.disabled(changes == 0)
                    }.fixedSize().disabled(model.busy)
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if game.enabled || game.installed != nil { diagnostics }
                    if loaded {
                        let rows = matching
                        if model.achievements.isEmpty {
                            EmptyMessage(icon: "trophy", title: model.tr("没有成就条目", "No achievements"), detail: model.tr("Steam 未返回这款游戏的成就。", "Steam returned no achievements for this game."))
                        } else if rows.isEmpty {
                            EmptyMessage(icon: "magnifyingglass", title: model.tr("没有匹配的成就", "No matching achievements"), detail: model.tr("试试其他名称或成就 ID。", "Try another name or achievement ID."))
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { row in
                                    achievementRow(row)
                                    if row.id != rows.last?.id { Divider() }
                                }
                            }
                        }
                    } else if model.busy {
                        ProgressView(model.progress).frame(maxWidth: .infinity).padding(.vertical, 50)
                    } else {
                        if !model.steamRunning {
                            EmptyMessage(icon: "person.crop.circle", title: model.tr("请先登录 Steam", "Sign in to Steam"), detail: model.tr("启动原生 Steam 并登录拥有这款游戏的账号，然后读取成就。", "Launch native Steam and sign in with an account that owns this game, then load its achievements."))
                            Button(model.tr("启动 Steam", "Launch Steam")) { model.launchSteam() }
                                .frame(maxWidth: .infinity).disabled(model.testing)
                        } else if !model.achievementStatus.isEmpty {
                            Label(model.achievementStatus, systemImage: "info.circle")
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Text(model.tr("读取后即可编辑这款游戏的成就。", "Load this game's achievements to edit them.")).foregroundStyle(.secondary)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if model.busy {
                    HStack {
                        if loaded { ProgressView().controlSize(.small); Text(model.progress).font(.caption) }
                        Spacer()
                        if model.canCancelOperation { Button(model.tr("取消操作", "Cancel operation")) { model.cancel() } }
                    }
                } else if loaded && !model.achievementStatus.isEmpty {
                    Text(model.achievementStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    if loaded, let progress = model.achievementProgress[game.id] {
                        Text(model.tr("已解锁 \(progress.unlocked)/\(progress.total)", "\(progress.unlocked)/\(progress.total) unlocked")).font(.caption).monospacedDigit()
                    }
                    Spacer()
                    Button(model.tr("关闭", "Close"), action: requestClose).keyboardShortcut(.cancelAction).disabled(model.busy)
                    Button(changes == 0 ? saveTitle : "\(saveTitle) (\(changes))") { model.saveAchievements() }
                        .buttonStyle(.borderedProminent).disabled(!loaded || model.busy || changes == 0 || !model.steamRunning)
                }
            }.padding(16)
        }
        .frame(width: 720, height: 550)
        .onAppear { if model.steamRunning { model.readAchievements() } }
        .interactiveDismissDisabled(model.busy || changes > 0)
        .confirmationDialog(model.tr("放弃未保存的成就更改？", "Discard unsaved achievement changes?"), isPresented: $confirmDiscard) {
            Button(model.tr("放弃更改并关闭", "Discard and close"), role: .destructive) {
                model.achievements = model.originalAchievements
                dismiss()
            }
            Button(model.tr("继续编辑", "Keep editing"), role: .cancel) {}
        }
    }

    private func requestClose() {
        if !model.achievementChanges.isEmpty { confirmDiscard = true } else { dismiss() }
    }

    private func achievementRow(_ row: Achievement) -> some View {
        HStack(alignment: .top, spacing: 12) {
            let title = row.name.isEmpty ? row.id : row.name
            Toggle(title, isOn: Binding(get: { row.achieved }, set: { unlocked in
                if let index = model.achievements.firstIndex(where: { $0.id == row.id }) {
                    model.achievements[index].achieved = unlocked
                }
            })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary) }
                if title != row.id { Text(row.id).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
            }
            Spacer()
            if row.achieved, row.unlockedAt > 0 {
                Text(Date(timeIntervalSince1970: TimeInterval(row.unlockedAt)), style: .date).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 9)
    }

    private var diagnostics: some View {
        DisclosureGroup(model.tr("兼容性与启动检查", "Compatibility and startup checks")) {
            VStack(alignment: .leading, spacing: 10) {
                if game.enabled {
                    Button(model.tr("初始化兼容成就", "Initialize compatible achievements")) { model.repairAchievements() }
                        .disabled(model.busy || !model.steamRunning || !model.achievementChanges.isEmpty)
                    Text(model.tr("若读取时返回 EResult=2，可获取公开成就定义。完成后请重启 Steam，再重新读取。", "If loading returns EResult=2, fetch the public achievement definitions. Restart Steam afterward, then reload."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let installed = game.installed { GameStartupPanel(game: installed) }
            }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
