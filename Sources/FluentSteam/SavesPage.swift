import SwiftUI
import FluentCore

struct SavesPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var query = ""
    @ViewState<Bool> private var onlyWithSaves = false
    @ViewState<Int> private var page = 0
    @ViewState<CloudProvider> private var provider = .local
    @ViewState<Set<Int>> private var managed = []
    private let pageSize = 8
    private var games: [ManagedSaveGame] { SaveManagement.filtered(model.managedSaveGames, query: query, onlyWithSaves: onlyWithSaves) }
    private var pages: Int { max(1, (games.count + pageSize - 1) / pageSize) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: model.tr("存档管理", "Save manager"), subtitle: model.tr("按游戏查看存档；在独立窗口中备份、恢复与设置同步。", "Browse by game. Back up, restore and configure sync in a dedicated window.")) {
                SaveManagerShortcut().buttonStyle(.borderedProminent)
            }
            HStack(spacing: 16) {
                Panel(padding: 16) {
                    Label(model.tr("存档目录", "Save folders"), systemImage: "folder")
                    Text(model.tr("\(model.managedSaveGames.filter { !$0.locations.isEmpty }.count) 款游戏 · \(model.saves.count) 个候选目录", "\(model.managedSaveGames.filter { !$0.locations.isEmpty }.count) games · \(model.saves.count) candidate folders")).font(.caption).foregroundStyle(.secondary)
                }
                Panel(padding: 16) {
                    HStack { Label(model.tr("\(model.saveManagerState.backups.count) 份存档备份", "\(model.saveManagerState.backups.count) save backups"), systemImage: "clock.arrow.circlepath"); Spacer(); SaveManagerShortcut(section: .history) }
                    Text(model.tr("游戏进度与配置回退分开管理", "Game saves and configuration rollback are separate")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel(padding: 16) {
                HStack {
                    Label(model.tr("游戏列表", "Games"), systemImage: "gamecontroller").font(.headline)
                    Spacer()
                    Toggle(model.tr("仅有存档 / 备份", "With saves / backups"), isOn: $onlyWithSaves).toggleStyle(.checkbox)
                    TextField(model.tr("搜索名称或 AppID", "Name or AppID"), text: $query).textFieldStyle(.roundedBorder).frame(width: 210)
                }
                if games.isEmpty {
                    EmptyMessage(icon: "folder.badge.questionmark", title: model.tr("没有匹配的游戏", "No matching games"), detail: model.tr("试试其他关键词或取消筛选。没有自动检测到存档的游戏，也可以在管理窗口添加目录。", "Try another search or clear the filter. Add folders in the manager for games without detected saves."))
                } else {
                    ForEach(Array(games.dropFirst(min(page, pages - 1) * pageSize).prefix(pageSize))) { game in
                        HStack(spacing: 14) {
                            Image(systemName: "gamecontroller").font(.title3).foregroundStyle(Palette.accent).frame(width: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(game.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text("App \(game.id) · " + model.tr("\(game.locations.count) 个目录 · \(game.backupCount) 份备份", "\(game.locations.count) folders · \(game.backupCount) backups")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Pill(text: managed.contains(game.id) ? ([CloudProvider.local, .folder].contains(provider) ? model.tr("本地接管", "Local storage") : provider.title) : model.tr("未接管", "Not redirected"), color: managed.contains(game.id) ? Palette.accent : .secondary)
                            SaveManagerShortcut(appID: game.id)
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    HStack {
                        Text(model.tr("共 \(games.count) 款 · 每页 \(pageSize) 款", "\(games.count) games · \(pageSize) per page")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).help(model.tr("上一页", "Previous page"))
                        Text("\(min(page, pages - 1) + 1) / \(pages)").font(.caption).monospacedDigit().frame(width: 55)
                        Button { page = min(pages - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= pages - 1).help(model.tr("下一页", "Next page"))
                    }
                }
            }
            HStack {
                Label(model.tr("本地接管不等于在线云同步；详细服务商设置在独立窗口内。", "Local redirection is not online cloud sync. Configure providers in the manager."), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                Spacer(); SaveManagerShortcut(section: .cloud)
            }
        }
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: onlyWithSaves) { _, _ in page = 0 }
        .onChange(of: pages) { _, value in page = min(page, value - 1) }
        .task { refreshCloud() }
        .onChange(of: model.lastRefresh) { _, _ in refreshCloud() }
    }
    private func refreshCloud() {
        guard let cloud = try? CloudConfiguration.load(paths: model.paths) else { managed = []; return }
        provider = cloud.provider; managed = Set((try? cloud.selectedApps(paths: model.paths)) ?? [])
    }
}
