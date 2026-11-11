import SwiftUI
import FluentCore

struct DiscoverPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DiscoverySearchContent(flow: model.discoverySearch) }
}

private struct DiscoverySearchContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: DiscoverySearchFlow
    @ViewState<Bool> private var dlc = true
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("发现下一款游戏", "Find your next game"), subtitle: model.tr("通过游戏名称或 AppID 搜索，一键添加到游戏库。", "Search by game name or AppID and add to your library in one click.")) { EmptyView() }
            Panel {
                HStack(spacing: 13) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(Palette.accent)
                    TextField(model.tr("输入游戏名称或 AppID，例如 480", "Game title or AppID, e.g. 480"), text: $model.search).textFieldStyle(.plain).font(.system(size: 16)).onSubmit { model.searchGames() }
                    Button(model.tr("搜索", "Search")) { model.searchGames() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                }
                Divider().padding(.vertical, 10)
                HStack { Toggle(model.tr("同时查询 DLC", "Include DLC"), isOn: $dlc).toggleStyle(.checkbox); Spacer(); Text(model.tr("简体中文名称 · 支持原生 / Windows depot", "Localized names · native / Windows depots")).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            DiscoveryChartsPanel(isExpanded: $flow.chartsExpanded)
            if flow.query.isEmpty {
                EmptyMessage(icon: "sparkle.magnifyingglass", title: model.tr("搜索，然后添加到你的游戏库", "Search, then add to your library"), detail: model.tr("自动获取并检查内容，缺项时尝试备用来源。仍不完整时会提示；入库后可在 Steam 下载游戏。", "Content is checked automatically, with another source tried when needed. Any remaining gaps are shown; download the game in Steam after adding it."))
            } else if flow.results.isEmpty && !flow.loading && flow.error.isEmpty && flow.nextOffset == nil {
                EmptyMessage(icon: "magnifyingglass", title: model.tr("没有找到相关游戏", "No games found"), detail: model.tr("试试其他名称或 AppID。", "Try another title or AppID."))
            }
            ForEach(flow.results) { item in
                DiscoverySearchRow(item: item, includeDLC: dlc)
            }
            if !flow.query.isEmpty { searchFooter.id(flow.nextOffset) }
        }
        .onChange(of: model.search) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flow.clear() }
        }
    }

    private var searchFooter: some View {
        VStack(spacing: 10) {
            if flow.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.tr("正在加载搜索结果…", "Loading search results…"))
                }
            } else if !flow.error.isEmpty {
                Text(flow.error).multilineTextAlignment(.center)
                Button(model.tr("重试", "Retry")) { flow.loadMore() }
            } else if flow.nextOffset != nil {
                Text(model.tr("已加载 \(flow.results.count) 个结果 · 继续下滑加载更多", "\(flow.results.count) results loaded · Scroll for more"))
            } else if !flow.results.isEmpty {
                Text(model.tr("已显示全部 \(flow.results.count) 个结果", "All \(flow.results.count) results shown"))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .onGeometryChange(for: Bool.self) { geometry in
            guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return false }
            return viewport.intersects(CGRect(origin: .zero, size: geometry.size))
        } action: { visible in
            if visible && flow.error.isEmpty { flow.loadMore() }
        }
    }
}

private struct DiscoverySearchRow: View {
    @EnvironmentObject var model: AppModel
    let item: GameMetadata
    let includeDLC: Bool

    var body: some View {
        Panel(padding: 15) {
            HStack(spacing: 18) {
                Cover(id: item.id, name: item.name, height: 95, imageURL: item.image).frame(width: 205).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.name).font(.system(size: 16, weight: .semibold))
                    HStack { Text("AppID \(String(item.id))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary); if item.mac { Pill(text: "macOS", color: Palette.green) }; if item.windows { Pill(text: "Windows · NotProton") } }
                    if model.games.contains(where: { $0.id == item.id && $0.enabled }) { Text(model.tr("已在 macSteam 游戏库", "Already enabled in macSteam")).font(.system(size: 11)).foregroundStyle(Palette.green) }
                }
                Spacer()
                VStack(spacing: 9) {
                    Button(model.games.contains(where: { $0.id == item.id && $0.enabled }) ? model.tr("已入库", "Added") : model.tr("一键入库", "Add to library")) { model.addToLibrary(item.id, dlc: includeDLC) }.buttonStyle(.borderedProminent).disabled(model.busy || model.games.contains(where: { $0.id == item.id && $0.enabled }))
                    Button(model.tr("商店详情 ↗", "Store details ↗")) { model.openURL("https://store.steampowered.com/app/\(item.id)") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
