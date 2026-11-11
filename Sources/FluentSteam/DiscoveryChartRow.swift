import SwiftUI
import FluentCore

private struct ChartTailPosition: PreferenceKey {
    static let defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}
struct DiscoveryChartRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: DiscoveryChartsFlow
    let title: String
    let games: [GameMetadata]
    @ViewState<CGFloat> private var tail = .infinity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Text(model.tr("左右滚动查看更多", "Scroll sideways for more")).font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(games) { game in
                            card(game).frame(width: 140).id(game.id).background {
                                if game.id == games.last?.id {
                                    GeometryReader { card in
                                        Color.clear.preference(key: ChartTailPosition.self, value: card.frame(in: .named(title)).minX)
                                    }
                                }
                            }
                        }
                        if flow.loadingMore { ProgressView().controlSize(.small).frame(width: 90, height: 66) }
                        else if !flow.moreError.isEmpty {
                            VStack(spacing: 6) {
                                Text(model.tr("加载失败", "Could not load more")).font(.caption).foregroundStyle(.secondary)
                                Button(model.tr("重试", "Retry")) { flow.loadMore(retry: true) }
                            }.frame(width: 110, height: 66).help(flow.moreError)
                        } else if !flow.hasMore {
                            Text(model.tr("已全部加载", "All loaded")).font(.caption).foregroundStyle(.secondary).frame(width: 100, height: 66)
                        }
                    }.frame(minWidth: viewport.size.width, alignment: .leading)
                    .accessibilityRepresentation {
                        // A plain accessibility group avoids the SDK's lazy-list
                        // endpoint scan, which traps after content is appended.
                        HStack {
                            ForEach(games) { game in
                                Button(game.name) { search(game) }.disabled(model.busy)
                            }
                            if !flow.moreError.isEmpty { Button(model.tr("重试", "Retry")) { flow.loadMore(retry: true) } }
                        }
                        .accessibilityElement(children: .contain).accessibilityLabel(title)
                        .accessibilityScrollAction { edge in
                            // Edge describes content motion: leading reveals later items.
                            let start = edge == .trailing || edge == .bottom
                            if let game = start ? games.first : games.last {
                                proxy.scrollTo(game.id, anchor: start ? .leading : .trailing)
                            }
                        }
                    }
                }.scrollIndicators(.hidden).coordinateSpace(name: title)
                .onPreferenceChange(ChartTailPosition.self) { position in tail = position; loadNearEnd(width: viewport.size.width) }
                .onChange(of: flow.loading) { _, loading in if !loading { loadNearEnd(width: viewport.size.width) } }
                .onChange(of: viewport.size.width) { _, _ in loadNearEnd(width: viewport.size.width) }
                }
            }.frame(height: 106)
        }.padding(.top, 8)
    }
    private func loadNearEnd(width: CGFloat) {
        if tail < width + 152 { flow.loadMore() }
    }
    private func card(_ game: GameMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Cover(id: game.id, name: game.name, height: 66, imageURL: game.image).onTapGesture { search(game) }
            Button { search(game) } label: {
                Text(game.name).lineLimit(2).font(.caption).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            }.buttonStyle(.plain).disabled(model.busy)
        }
    }
    private func search(_ game: GameMetadata) {
        guard !model.busy else { return }
        model.search = String(game.id); model.searchGames()
    }
}
