import Foundation
import Testing
@testable import MacSteamToolCore

struct SteamSearchTests {
    private func row(_ path: String, title: String = "Game", extra: String = "") -> String {
        """
        <a href="https://store.steampowered.com/\(path)/?snr=1" data-ds-appid="1,2" class="search_result_row ds_collapse_flag">
          <div><img src="https://shared.akamai.steamstatic.com/image.jpg?a=1&amp;b=2"></div>
          <span class="title">\(title)</span><span class="platform_img win"></span>\(extra)
        </a>
        """
    }

    @Test func decodesAppsEntitiesAndPlatformsAndAdvancesPastPackages() throws {
        let html = row("app/400/Portal", title: "Portal &amp; Friends &#39;测试&#39; &#x1F3AE;", extra: "<span class=\"platform_img mac\"></span>")
            + row("sub/12") + row("bundle/99") + row("app/620/Portal_2") + row("app/620/Portal_2")
        let page = try SteamSearchPage.decode(["success": 1, "start": 25, "total_count": 100, "results_html": html], offset: 25)
        #expect(page.games.map(\.id) == [400, 620]); #expect(page.nextOffset == 30)
        #expect(page.games[0].name == "Portal & Friends '测试' 🎮")
        #expect(page.games[0].image.hasSuffix("?a=1&b=2"))
        #expect(page.games[0].mac && page.games[0].windows); #expect(!page.games[1].mac)
    }

    @Test func lastPageAndNoResultsTerminate() throws {
        let last = try SteamSearchPage.decode(["success": 1, "start": 25, "total_count": 26, "results_html": row("app/400")], offset: 25)
        #expect(last.games.count == 1); #expect(last.nextOffset == nil)
        let empty = try SteamSearchPage.decode(["success": 1, "start": 0, "total_count": 0, "results_html": "<!-- empty -->"], offset: 0)
        #expect(empty.games.isEmpty); #expect(empty.nextOffset == nil)
    }

    @Test func rejectsFailuresBrokenMarkupAndServerResettingPage() {
        for data: [String: Any] in [
            ["success": 0],
            ["success": 1, "start": 0, "total_count": 50, "results_html": row("app/400")],
            ["success": 1, "start": 25, "total_count": 50, "results_html": row("app/400").replacingOccurrences(of: "class=\"title\"", with: "class=\"renamed\"")],
            ["success": 1, "start": 25, "total_count": 50, "results_html": "<div>Changed markup</div>"]
        ] {
            #expect(throws: AppFailure.self) { try SteamSearchPage.decode(data, offset: 25) }
        }
    }

    @Test func appIDLookupRemainsASingleResultWithoutPagination() async throws {
        let cache = FileStore.fm.temporaryDirectory.appendingPathComponent("SteamSearch-\(UUID())")
        defer { try? FileStore.fm.removeItem(at: cache) }
        try FileStore.json(GameMetadata(id: 620, name: "Portal 2"), to: cache.appendingPathComponent("schinese-620.json"))
        let api = SteamAPI(cache: cache)
        let page = try await api.searchPage(" 620 ")
        #expect(page.games.map(\.id) == [620]); #expect(page.nextOffset == nil)
        let next = try await api.searchPage("620", offset: 25)
        #expect(next.games.isEmpty); #expect(next.nextOffset == nil)
    }
}
