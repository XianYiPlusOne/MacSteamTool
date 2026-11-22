import Foundation
import Testing
@testable import MacSteamToolCore

private actor ChartCalls {
    var count = 0
    func next() { count += 1 }
}
@Suite struct DiscoveryChartsTests {
    func root() throws -> URL {
        let file = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentCharts-\(UUID())")
        try FileStore.mkdir(file); return file
    }
    @Test func onePagePreservesHeyboxArtworkAndFiltersInvalidRows() async throws {
        let calls = ChartCalls()
        let image = "https://heyboxbj.max-c.com/gameimg/steam_item_assets/hash-only.jpg?imageMogr2/thumbnail/460x215%3E/format/webp"
        let body: [String: Any] = ["result": ["list": [
            ["appid": "12345", "game_name": "", "name": "Game", "game_img": image],
            ["appid": 12345, "name": "Duplicate"], ["appid": "../bad", "name": "Bad"],
            ["appid": 12346, "name": "Other", "game_img": "https://evil.example/image.jpg"]
        ]]]
        let bytes = try JSONSerialization.data(withJSONObject: body)
        let games = try await DiscoveryCharts.load { url in
            await calls.next()
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first { $0.name == "offset" }?.value == "0")
            #expect(query.first { $0.name == "limit" }?.value == "30")
            return bytes
        }
        #expect(await calls.count == 1); #expect(games.map(\.id) == [12345, 12346])
        #expect(games[0].image == image); #expect(games[1].image.isEmpty)
        #expect(throws: (any Error).self) { try DiscoveryCharts.parse(Data("{\"result\":{\"list\":[]}}".utf8)) }
        #expect(throws: (any Error).self) { try DiscoveryCharts.parse(Data("<html>error</html>".utf8)) }
    }
    @Test func refreshCoalescesAndFreshDiskCacheAvoidsNetwork() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json"), calls = ChartCalls()
        let store = DiscoveryChartStore(file: file) { _ in await calls.next(); try await Task.sleep(for: .milliseconds(50)); return DiscoveryChartPage(games: [GameMetadata(id: 12345, name: "Game")], nextOffset: 30, hasMore: true) }
        try await withThrowingTaskGroup(of: DiscoveryChartSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await store.refresh(force: true) } }
            for try await item in group { #expect(item.games.first?.id == 12345) }
        }
        #expect(await calls.count == 1)
        let offline = DiscoveryChartStore(file: file) { _ in Issue.record("Fresh cache unexpectedly fetched"); throw URLError(.notConnectedToInternet) }
        #expect(try await offline.refresh().games.first?.id == 12345)
    }
    @Test func failedRefreshRetainsStaleCacheAndMalformedCacheIsIgnored() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json")
        let item = DiscoveryChartSnapshot(date: Date().addingTimeInterval(-7200), games: [GameMetadata(id: 12345, name: "Cached")])
        try FileStore.json(item, to: file); let before = try FileStore.read(file)
        let store = DiscoveryChartStore(file: file) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await store.cached()?.games.first?.name == "Cached")
        await #expect(throws: (any Error).self) { try await store.refresh() }
        #expect(await store.cached()?.games.first?.name == "Cached"); #expect(try FileStore.read(file) == before)
        try FileStore.write(Data("broken".utf8), to: file)
        let recover = DiscoveryChartStore(file: file) { _ in DiscoveryChartPage(games: [GameMetadata(id: 12346, name: "Recovered")], nextOffset: 30, hasMore: false) }
        #expect(await recover.cached() == nil); #expect(try await recover.refresh().games.first?.id == 12346)
    }
    @Test func invalidRefreshDoesNotReplaceLastGoodSnapshot() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json")
        try FileStore.json(DiscoveryChartSnapshot(games: [GameMetadata(id: 12345, name: "Keep")]), to: file)
        let before = try FileStore.read(file)
        let store = DiscoveryChartStore(file: file) { _ in DiscoveryChartPage(games: [], nextOffset: 0, hasMore: false) }
        await #expect(throws: (any Error).self) { try await store.refresh(force: true) }
        #expect(try FileStore.read(file) == before); #expect(await store.cached()?.games.first?.name == "Keep")
    }
}

private actor PagedChartFeed {
    var offsets: [Int] = []
    var fail = false
    func failOnce() { fail = true }
    func page(_ offset: Int) async throws -> DiscoveryChartPage {
        offsets.append(offset); try await Task.sleep(for: .milliseconds(30))
        if fail { fail = false; throw URLError(.notConnectedToInternet) }
        let ids = offset == 0 ? Array(100..<130) : offset == 30 ? Array(125..<155) : []
        return DiscoveryChartPage(games: ids.map { GameMetadata(id: $0, name: "Game \($0)") }, nextOffset: offset == 0 ? 30 : 60, hasMore: !ids.isEmpty)
    }
}
@Suite struct DiscoveryChartPaginationTests {
    @Test func rawOffsetsShortPageAndEmptyEndAreParsed() async throws {
        var rows = (100..<130).map { ["appid": $0, "game_name": "Game \($0)"] as [String: Any] }
        rows[29] = rows[0]
        let bytes = try JSONSerialization.data(withJSONObject: ["result": ["list": rows, "total_page": 3]])
        let page = try await DiscoveryCharts.loadPage(offset: 30) { url in
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "offset" }?.value == "30")
            return bytes
        }
        #expect(page.games.count == 29); #expect(page.nextOffset == 60); #expect(page.hasMore)
        let empty = try await DiscoveryCharts.loadPage(offset: 60) { _ in Data("{\"result\":{\"list\":[]}}".utf8) }
        #expect(empty.games.isEmpty); #expect(empty.nextOffset == 60); #expect(!empty.hasMore)
        let short = try await DiscoveryCharts.loadPage(offset: 60) { _ in Data("{\"result\":{\"list\":[{\"appid\":999,\"name\":\"Last\"}]}}".utf8) }
        #expect(short.games.count == 1); #expect(short.nextOffset == 61); #expect(!short.hasMore)
    }
    @Test func appendCoalescesDeduplicatesAndResumesFromDiskAfterFailure() async throws {
        let root = try DiscoveryChartsTests().root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json"), feed = PagedChartFeed()
        let store = DiscoveryChartStore(file: file) { try await feed.page($0) }
        let first = try await store.refresh()
        try await withThrowingTaskGroup(of: DiscoveryChartSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await store.loadMore() } }
            for try await item in group { #expect(item.games.count == 55); #expect(item.date == first.date) }
        }
        #expect(await feed.offsets == [0, 30])
        let restored = DiscoveryChartStore(file: file) { try await feed.page($0) }
        #expect(await restored.cached()?.nextOffset == 60)
        let before = try FileStore.read(file)
        await feed.failOnce()
        await #expect(throws: (any Error).self) { try await restored.loadMore() }
        #expect(try FileStore.read(file) == before); #expect(await restored.cached()?.games.count == 55)
        let end = try await restored.loadMore()
        #expect(end.games.count == 55); #expect(!end.canLoadMore)
        _ = try await restored.loadMore()
        #expect(await feed.offsets == [0, 30, 60, 60])
    }
    @Test func ignoredOffsetStopsAndLegacyCacheRetainsCursor() async throws {
        let root = try DiscoveryChartsTests().root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json")
        let games = (100..<130).map { GameMetadata(id: $0, name: "Cached \($0)") }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DiscoveryChartSnapshot(games: games))) as! [String: Any]
        legacy["version"] = 1; legacy.removeValue(forKey: "nextOffset"); legacy.removeValue(forKey: "hasMore")
        try FileStore.write(JSONSerialization.data(withJSONObject: legacy), to: file)
        let calls = ChartCalls()
        let store = DiscoveryChartStore(file: file) { offset in
            await calls.next(); #expect(offset == 30)
            return DiscoveryChartPage(games: games, nextOffset: 60, hasMore: true)
        }
        #expect(await store.cached()?.games.count == 30)
        let item = try await store.loadMore()
        #expect(item.games.count == 30); #expect(!item.canLoadMore)
        _ = try await store.loadMore(); #expect(await calls.count == 1)
    }
}
