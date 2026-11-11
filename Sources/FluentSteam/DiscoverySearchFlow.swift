import SwiftUI
import FluentCore

@MainActor final class DiscoverySearchFlow: ObservableObject {
    @Published private(set) var results: [GameMetadata] = []
    @Published private(set) var query = ""
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    @Published private(set) var nextOffset: Int?
    @Published var chartsExpanded = true
    private(set) var operation: Task<Void, Never>?
    private var generation = UUID()
    private var language = "schinese"
    private let fetch: (String, String, Int) async throws -> SteamSearchPage

    init(fetch: @escaping (String, String, Int) async throws -> SteamSearchPage) { self.fetch = fetch }

    func search(_ text: String, language: String) {
        clear()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        self.language = language
        chartsExpanded = false
        nextOffset = 0
        loadMore()
    }

    func clear() {
        operation?.cancel()
        operation = nil
        generation = UUID()
        results = []; query = ""; error = ""; nextOffset = nil; loading = false
        chartsExpanded = true
    }

    func loadMore() {
        guard operation == nil, let offset = nextOffset, !query.isEmpty else { return }
        let generation = generation, query = query, language = language
        loading = true; error = ""
        operation = Task {
            defer {
                if self.generation == generation { loading = false; operation = nil }
            }
            do {
                let page = try await fetch(query, language, offset)
                guard !Task.isCancelled, self.generation == generation else { return }
                var seen = Set(results.map(\.id))
                results.append(contentsOf: page.games.filter { seen.insert($0.id).inserted })
                nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
