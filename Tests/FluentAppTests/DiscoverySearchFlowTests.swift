import Foundation
import Testing
@testable import FluentSteam
@testable import FluentCore

private actor SearchGate {
    struct Request: Equatable { let query: String; let language: String; let offset: Int }
    var requests: [Request] = []
    var pending: [Int: CheckedContinuation<SteamSearchPage, Error>] = [:]
    func fetch(_ query: String, _ language: String, _ offset: Int) async throws -> SteamSearchPage {
        let index = requests.count
        requests.append(Request(query: query, language: language, offset: offset))
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, ids: [Int], next: Int?) {
        pending.removeValue(forKey: index)?.resume(returning: SteamSearchPage(games: ids.map { GameMetadata(id: $0, name: "Game \($0)") }, nextOffset: next))
    }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: AppFailure("Offline")) }
}

@Suite @MainActor struct DiscoverySearchFlowTests {
    private func wait(_ gate: SearchGate, calls: Int) async throws {
        for _ in 0..<100 {
            if await gate.requests.count == calls { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppFailure("Search did not reach expected state")
    }

    @Test func appendsDeduplicatesAndStopsAtEndWithoutOverlappingRequests() async throws {
        let gate = SearchGate(), flow = DiscoverySearchFlow { try await gate.fetch($0, $1, $2) }
        flow.search("  Portal  ", language: "english")
        #expect(!flow.chartsExpanded)
        for _ in 0..<5 { flow.loadMore() }
        try await wait(gate, calls: 1)
        #expect(await gate.requests == [.init(query: "Portal", language: "english", offset: 0)])
        await gate.finish(0, ids: [400, 620], next: 25); await flow.operation?.value
        #expect(flow.results.map(\.id) == [400, 620]); #expect(!flow.loading)
        flow.chartsExpanded = true
        flow.loadMore(); try await wait(gate, calls: 2)
        #expect(await gate.requests.last?.offset == 25)
        #expect(flow.results.count == 2); #expect(flow.chartsExpanded)
        await gate.finish(1, ids: [620, 374040, 374040], next: nil); await flow.operation?.value
        #expect(flow.results.map(\.id) == [400, 620, 374040])
        flow.loadMore()
        #expect(flow.operation == nil); #expect(await gate.requests.count == 2)
    }

    @Test func pageFailureKeepsResultsAndRetriesSameQueryLanguageAndOffset() async throws {
        let gate = SearchGate(), flow = DiscoverySearchFlow { try await gate.fetch($0, $1, $2) }
        flow.search("Portal", language: "schinese"); try await wait(gate, calls: 1)
        await gate.finish(0, ids: [400], next: 25); await flow.operation?.value
        flow.loadMore(); try await wait(gate, calls: 2)
        await gate.fail(1); await flow.operation?.value
        #expect(flow.results.map(\.id) == [400]); #expect(flow.nextOffset == 25)
        #expect(!flow.error.isEmpty); #expect(!flow.loading)
        flow.loadMore(); try await wait(gate, calls: 3)
        #expect(await gate.requests[1] == gate.requests[2])
        await gate.finish(2, ids: [620], next: nil); await flow.operation?.value
        #expect(flow.results.map(\.id) == [400, 620]); #expect(flow.error.isEmpty)
    }

    @Test func newSearchIgnoresOldCompletionAndClearRestoresCharts() async throws {
        let gate = SearchGate(), flow = DiscoverySearchFlow { try await gate.fetch($0, $1, $2) }
        flow.search("old", language: "schinese"); try await wait(gate, calls: 1)
        let old = flow.operation
        flow.chartsExpanded = true
        flow.search("new", language: "english"); try await wait(gate, calls: 2)
        #expect(!flow.chartsExpanded)
        await gate.finish(0, ids: [1], next: 25); await old?.value
        #expect(flow.results.isEmpty); #expect(flow.loading)
        await gate.finish(1, ids: [2], next: 25); await flow.operation?.value
        #expect(flow.results.map(\.id) == [2])
        flow.loadMore(); try await wait(gate, calls: 3)
        let cancelled = flow.operation
        flow.clear()
        await gate.finish(2, ids: [3], next: nil); await cancelled?.value
        #expect(flow.results.isEmpty); #expect(flow.query.isEmpty); #expect(flow.chartsExpanded)
        #expect(!flow.loading); #expect(flow.nextOffset == nil)
    }

    @Test func firstPageFailureCanRetryAndEmptySearchDoesNotRequest() async throws {
        let gate = SearchGate(), flow = DiscoverySearchFlow { try await gate.fetch($0, $1, $2) }
        flow.search(" \n ", language: "english")
        #expect(flow.chartsExpanded); #expect(flow.operation == nil)
        flow.search("missing", language: "english"); try await wait(gate, calls: 1)
        await gate.fail(0); await flow.operation?.value
        #expect(flow.nextOffset == 0); #expect(!flow.error.isEmpty)
        flow.loadMore(); try await wait(gate, calls: 2)
        await gate.finish(1, ids: [], next: nil); await flow.operation?.value
        #expect(flow.results.isEmpty); #expect(flow.error.isEmpty); #expect(flow.nextOffset == nil)
        #expect(!flow.chartsExpanded)
    }
}
