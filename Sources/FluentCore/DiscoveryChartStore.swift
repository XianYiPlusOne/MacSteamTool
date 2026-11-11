import Foundation

public struct DiscoveryChartSnapshot: Codable, Sendable {
    public let version: Int
    public let date: Date
    public let games: [GameMetadata]
    public let nextOffset: Int?
    public let hasMore: Bool?
    public var canLoadMore: Bool { (hasMore ?? true) && games.count < DiscoveryCharts.maximumGames && (nextOffset ?? DiscoveryCharts.pageSize) < DiscoveryCharts.maximumGames }
    public init(date: Date = Date(), games: [GameMetadata], nextOffset: Int = DiscoveryCharts.pageSize, hasMore: Bool = true) {
        version = 2; self.date = date; self.games = games; self.nextOffset = nextOffset; self.hasMore = hasMore
    }
    public func isFresh(at now: Date = Date()) -> Bool { date.timeIntervalSince(now) < 300 && now.timeIntervalSince(date) < 1800 }
}
public actor DiscoveryChartStore {
    public typealias Fetch = @Sendable (Int) async throws -> DiscoveryChartPage
    private let file: URL
    private let fetch: Fetch
    private var current: DiscoveryChartSnapshot?
    private var pending: Task<DiscoveryChartSnapshot, Error>?
    public init(file: URL, fetch: @escaping Fetch = { try await DiscoveryCharts.loadPage(offset: $0) }) { self.file = file; self.fetch = fetch }
    public func cached() -> DiscoveryChartSnapshot? {
        if let current { return current }
        guard let item = try? FileStore.decode(DiscoveryChartSnapshot.self, at: file), [1, 2].contains(item.version),
              !item.games.isEmpty, item.games.count <= DiscoveryCharts.maximumGames,
              item.nextOffset.map({ (0...DiscoveryCharts.maximumGames).contains($0) }) != false,
              Self.valid(item.games) else { return nil }
        current = item; return item
    }
    public func refresh(force: Bool = false) async throws -> DiscoveryChartSnapshot {
        if let pending { return try await pending.value }
        if !force, let item = cached(), item.isFresh() { return item }
        let fetch = fetch
        return try await request {
            let page = try await fetch(0)
            guard !page.games.isEmpty, Self.validPage(page, after: 0) else { throw AppFailure("榜单内容无效 / Invalid chart data") }
            return DiscoveryChartSnapshot(games: page.games, nextOffset: page.nextOffset, hasMore: page.hasMore)
        }
    }
    public func loadMore() async throws -> DiscoveryChartSnapshot {
        if let pending { return try await pending.value }
        guard let old = cached() else { return try await refresh() }
        guard old.canLoadMore else { return old }
        let offset = old.nextOffset ?? DiscoveryCharts.pageSize, fetch = fetch
        return try await request {
            let page = try await fetch(offset)
            guard Self.validPage(page, after: offset) else { throw AppFailure("榜单分页内容无效 / Invalid chart page") }
            let seen = Set(old.games.map(\.id)), added = page.games.filter { !seen.contains($0.id) }
            let games = Array((old.games + added).prefix(DiscoveryCharts.maximumGames))
            return DiscoveryChartSnapshot(date: old.date, games: games, nextOffset: page.nextOffset,
                                          hasMore: page.hasMore && !added.isEmpty && games.count < DiscoveryCharts.maximumGames)
        }
    }
    private static func valid(_ games: [GameMetadata]) -> Bool {
        Set(games.map(\.id)).count == games.count && games.allSatisfy { TextUtil.validID(String($0.id)) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private static func validPage(_ page: DiscoveryChartPage, after offset: Int) -> Bool {
        page.games.count <= DiscoveryCharts.pageSize && valid(page.games) &&
        (offset...min(offset + DiscoveryCharts.pageSize, DiscoveryCharts.maximumGames)).contains(page.nextOffset) &&
        (!page.hasMore || page.nextOffset > offset)
    }
    private func request(_ work: @escaping @Sendable () async throws -> DiscoveryChartSnapshot) async throws -> DiscoveryChartSnapshot {
        let task = Task { try await work() }; pending = task
        do {
            let item = try await task.value; pending = nil; current = item
            try? FileStore.json(item, to: file)
            return item
        } catch { pending = nil; throw error }
    }
}
