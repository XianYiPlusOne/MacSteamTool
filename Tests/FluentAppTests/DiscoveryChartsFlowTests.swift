import Foundation
import Testing
@testable import FluentSteam
@testable import FluentCore

private actor ChartGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    var calls = 0
    var offsets: [Int] = []
    var fail = false
    func fetch(_ offset: Int = 0) async throws -> DiscoveryChartPage {
        calls += 1; entered = true; offsets.append(offset)
        await withCheckedContinuation { continuation = $0 }
        if fail { throw AppFailure("Synthetic refresh failure") }
        return DiscoveryChartPage(games: ((200 + offset)..<(225 + offset)).map { GameMetadata(id: $0, name: "New \($0)") }, nextOffset: offset + 30, hasMore: true)
    }
    func release(fail: Bool = false) { self.fail = fail; continuation?.resume(); continuation = nil }
}
@Suite @MainActor struct DiscoveryChartsFlowTests {
    func root() throws -> URL { let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentChartsFlow-\(UUID())"); try FileStore.mkdir(root); return root }
    func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AppFailure("Chart flow did not reach expected state")
    }
    @Test func pageEntryIgnoresCacheAndDoesNotBlockAppOperation() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json"), gate = ChartGate()
        try FileStore.json(DiscoveryChartSnapshot(date: Date().addingTimeInterval(-7200), games: (100..<125).map { GameMetadata(id: $0, name: "Old \($0)") }), to: file)
        let model = AppModel(fixtureHome: root, chartStore: DiscoveryChartStore(file: file) { _ in try await gate.fetch() })
        model.busy = true; model.progress = "Existing import"
        model.charts.load()
        try await waitUntil { await gate.entered }
        #expect(model.charts.popular.isEmpty); #expect(model.charts.updated == nil)
        #expect(model.charts.loading); #expect(model.busy); #expect(model.progress == "Existing import")
        await gate.release(); await model.charts.operation?.value
        #expect(model.charts.popular.map(\.id) == Array(200..<225))
        #expect(model.busy); #expect(model.message == nil); #expect(!model.charts.loading)
    }
    @Test func freshCacheAndImmediateReentryAlwaysFetchFirstPage() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json"), gate = ChartGate()
        try FileStore.json(DiscoveryChartSnapshot(games: [GameMetadata(id: 100, name: "Cached")]), to: file)
        let flow = DiscoveryChartsFlow(store: DiscoveryChartStore(file: file) { _ in try await gate.fetch() })
        flow.load(); try await waitUntil { await gate.calls == 1 }
        #expect(flow.popular.isEmpty)
        for _ in 0..<5 { flow.load() }
        #expect(flow.loading); #expect(await gate.calls == 1)
        await gate.release(); await flow.operation?.value
        #expect(flow.popular.first?.id == 200); #expect(await gate.calls == 1)
        flow.load(); try await waitUntil { await gate.calls == 2 }
        #expect(flow.popular.isEmpty); #expect(flow.updated == nil)
        await gate.release(); await flow.operation?.value
        #expect(flow.popular.count == 25); #expect(await gate.offsets == [0, 0])
    }
    @Test func refreshFailureDoesNotDisplayCachedRowsAndAllowsRetryWithoutGlobalAlert() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json"), gate = ChartGate()
        try FileStore.json(DiscoveryChartSnapshot(games: [GameMetadata(id: 100, name: "Cached")]), to: file)
        let model = AppModel(fixtureHome: root, chartStore: DiscoveryChartStore(file: file) { _ in try await gate.fetch() })
        model.charts.load(); try await waitUntil { await gate.entered }
        await gate.release(fail: true); await model.charts.operation?.value
        #expect(model.charts.popular.isEmpty); #expect(model.charts.updated == nil); #expect(!model.charts.error.isEmpty)
        #expect(model.message == nil); #expect(!model.busy); #expect(!model.charts.loading)
        model.charts.load(); try await waitUntil { await gate.calls == 2 }
        await gate.release(); await model.charts.operation?.value
        #expect(model.charts.error.isEmpty); #expect(model.charts.popular.first?.id == 200)
    }

    @Test func reentryDuringPaginationDiscardsOldPageAndRefreshesFromBeginning() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let gate = ChartGate()
        let flow = DiscoveryChartsFlow(store: DiscoveryChartStore(file: root.appendingPathComponent("popular.json")) { try await gate.fetch($0) })
        flow.load(); try await waitUntil { await gate.calls == 1 }
        await gate.release(); await flow.operation?.value
        flow.loadMore(); try await waitUntil { await gate.calls == 2 }
        flow.load()
        #expect(flow.loading); #expect(!flow.loadingMore); #expect(flow.popular.isEmpty)
        await gate.release(); try await waitUntil { await gate.calls == 3 }
        #expect(flow.loading); #expect(flow.popular.isEmpty)
        await gate.release(); await flow.operation?.value
        #expect(flow.popular.map(\.id) == Array(200..<225)); #expect(await gate.offsets == [0, 30, 0])
        #expect(!flow.loading); #expect(!flow.loadingMore); #expect(flow.operation == nil)
    }
}

private actor ScrollingChartFeed {
    var offsets: [Int] = []
    var failed = false
    func page(_ offset: Int) async throws -> DiscoveryChartPage {
        offsets.append(offset); try await Task.sleep(for: .milliseconds(30))
        if offset == 60 && !failed { failed = true; throw AppFailure("Synthetic page failure") }
        let ids = offset == 0 ? Array(100..<130) : offset == 30 ? Array(130..<160) : Array(160..<165)
        return DiscoveryChartPage(games: ids.map { GameMetadata(id: $0, name: "More \($0)") }, nextOffset: offset < 60 ? offset + 30 : 65, hasMore: offset < 60)
    }
}
@Suite @MainActor struct DiscoveryChartScrollingTests {
    @Test func scrollingAppendsStableRowsAndFailureRetriesSameCursorWithoutBlockingApp() async throws {
        let root = try DiscoveryChartsFlowTests().root(); defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("popular.json"), feed = ScrollingChartFeed()
        try FileStore.json(DiscoveryChartSnapshot(games: (100..<130).map { GameMetadata(id: $0, name: "Initial \($0)") }), to: file)
        let model = AppModel(fixtureHome: root, chartStore: DiscoveryChartStore(file: file) { try await feed.page($0) })
        let flow = model.charts
        flow.load(); await flow.operation?.value
        let popular = flow.popular.map(\.id)
        model.busy = true; model.progress = "Existing import"
        for _ in 0..<8 { flow.loadMore() }
        #expect(flow.loadingMore); await flow.operation?.value
        #expect(flow.popular.map(\.id) == Array(100..<160))
        #expect(Array(flow.popular.prefix(30).map(\.id)) == popular)
        #expect(await feed.offsets == [0, 30]); #expect(model.busy); #expect(model.progress == "Existing import")
        flow.loadMore(); await flow.operation?.value
        #expect(!flow.moreError.isEmpty); #expect(flow.popular.count == 60); #expect(model.message == nil)
        flow.loadMore(); #expect(flow.operation == nil)
        flow.loadMore(retry: true); await flow.operation?.value
        #expect(flow.moreError.isEmpty); #expect(!flow.hasMore); #expect(!flow.loadingMore)
        #expect(flow.popular.count == 65); #expect(await feed.offsets == [0, 30, 60, 60])
        flow.loadMore(); #expect(flow.operation == nil)
    }
}
