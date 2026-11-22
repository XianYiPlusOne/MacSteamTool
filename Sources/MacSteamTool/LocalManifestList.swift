import SwiftUI
import MacSteamToolCore

struct LocalManifestList: View {
    @EnvironmentObject private var model: AppModel
    @ViewState<LocalManifestCatalog?> private var catalog = nil
    @ViewState<String> private var search = ""

    private struct Refresh: Equatable {
        let cache: URL
        let games: [Game]
        let lastRefresh: Date
        let completed: Int
        let hubCompleted: Int
    }

    var body: some View {
        let refresh = Refresh(cache: model.paths.depotCache, games: model.games, lastRefresh: model.lastRefresh,
                              completed: model.monitorCompleted, hubCompleted: model.hubMonitorCompleted)
        Panel {
            HStack {
                Text(model.tr("本地清单", "Local manifests")).font(.headline)
                if let catalog {
                    Text(model.tr("\(catalog.games.count) 款游戏 · \(catalog.fileCount) 份清单",
                                  "\(catalog.games.count) games · \(catalog.fileCount) manifests"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let catalog, !catalog.games.isEmpty {
                    TextField(model.tr("搜索游戏名或 AppID", "Search by game or AppID"), text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
            }
            if let catalog {
                if catalog.fileCount == 0 {
                    EmptyMessage(icon: "tray", title: model.tr("还没有缓存清单", "No cached manifests"),
                                 detail: model.tr("Steam 缓存或手动导入的清单会显示在这里。", "Manifests cached by Steam or imported from a file appear here."))
                } else {
                    gameRows(catalog)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: refresh) {
            if let result = try? await LocalManifestCatalog.load(paths: model.paths, games: refresh.games), !Task.isCancelled {
                catalog = result
            }
        }
    }

    @ViewBuilder private func gameRows(_ catalog: LocalManifestCatalog) -> some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let games = catalog.games.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.id).contains(query) }
        let showUnidentified = !catalog.unidentified.isEmpty && (query.isEmpty || catalog.games.isEmpty)
        ForEach(games) { game in
            ManifestGroupRow(title: game.name, appID: game.id, entries: game.entries)
        }
        if showUnidentified {
            ManifestGroupRow(title: model.tr("未识别游戏", "Unidentified game"), appID: nil, entries: catalog.unidentified)
        }
        if games.isEmpty && !showUnidentified {
            Text(model.tr("没有匹配的游戏", "No matching games")).foregroundStyle(.secondary).padding(.vertical, 12)
        }
    }
}

private struct ManifestGroupRow: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let appID: Int?
    let entries: [LocalManifestCatalog.Entry]

    var body: some View {
        Divider()
        DisclosureGroup {
            ForEach(entries) { entry in
                HStack {
                    Text(entry.file.lastPathComponent).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if entry.shared { Pill(text: model.tr("共享", "Shared")) }
                    Spacer()
                    Button(model.tr("在 Finder 中显示", "Show in Finder")) { model.reveal(entry.file) }
                        .controlSize(.small)
                }.padding(.vertical, 3)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: appID == nil ? "questionmark.folder" : "gamecontroller").foregroundStyle(.secondary)
                Text(title).font(.body.weight(.semibold))
                if let appID { Text("AppID \(String(appID))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(model.tr("\(entries.count) 份清单", "\(entries.count) manifests"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
    }
}
