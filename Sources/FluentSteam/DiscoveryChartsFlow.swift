import Foundation
import SwiftUI
import FluentCore

@MainActor final class DiscoveryChartsFlow: ObservableObject {
    @Published private(set) var popular: [GameMetadata] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var moreError = ""
    @Published private(set) var error = ""
    @Published private(set) var updated: Date?
    var operation: Task<Void, Never>?
    private let store: DiscoveryChartStore
    private var generation = UUID()
    init(store: DiscoveryChartStore) { self.store = store }
    func load() {
        guard !loading else { return }
        let previous = operation
        previous?.cancel()
        let generation = UUID(); self.generation = generation
        popular = []; updated = nil; hasMore = false
        loading = true; loadingMore = false; error = ""; moreError = ""
        operation = Task {
            defer { if self.generation == generation { loading = false; operation = nil } }
            // Finish an older page request before forcing a fresh first page.
            // Its completion must not repopulate this newly opened page.
            await previous?.value
            guard !Task.isCancelled, self.generation == generation else { return }
            do {
                let item = try await store.refresh(force: true)
                guard !Task.isCancelled, self.generation == generation else { return }
                publish(item)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func loadMore(retry: Bool = false) {
        guard operation == nil, hasMore, !popular.isEmpty, moreError.isEmpty || retry else { return }
        let generation = generation
        loadingMore = true; moreError = ""
        operation = Task {
            defer { if self.generation == generation { loadingMore = false; operation = nil } }
            do {
                let item = try await store.loadMore()
                guard !Task.isCancelled, self.generation == generation else { return }
                publish(item)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                moreError = error.localizedDescription
            }
        }
    }
    private func publish(_ item: DiscoveryChartSnapshot) {
        popular = item.games; updated = item.date; hasMore = item.canLoadMore
    }
}
