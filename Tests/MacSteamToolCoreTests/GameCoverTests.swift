import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import MacSteamToolCore

private actor CoverRequests {
    var urls: [URL] = []
    var available = false
    var active = 0
    var maximum = 0
    func record(_ url: URL) { urls.append(url) }
    func begin(_ url: URL) { urls.append(url); active += 1; maximum = max(maximum, active) }
    func end() { active -= 1 }
    func enable() { available = true }
}
@Suite struct GameCoverTests {
    private func fixture() throws -> URL {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentCoverTests-\(UUID())")
        try FileStore.mkdir(root); return root
    }
    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let data = NSMutableData(), image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test func preservesHashedLocalizedAssetAndRestrictsReferences() {
        let raw = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/12345/abcdef/header_schinese.jpg?t=123"
        let urls = GameCovers.candidates(appID: 12345, reference: raw)
        #expect(urls.first?.absoluteString == raw); #expect(urls.count >= 3)
        #expect(urls.allSatisfy { $0.path == "/store_item_assets/steam/apps/12345/abcdef/header_schinese.jpg" && $0.query == "t=123" })
        for value in ["http://shared.akamai.steamstatic.com/steam/apps/12345/header.jpg", "https://evil.example/steam/apps/12345/header.jpg", "https://user:secret@shared.akamai.steamstatic.com/steam/apps/12345/header.jpg", "https://shared.akamai.steamstatic.com/steam/apps/99/header.jpg", "file:///tmp/header.jpg"] {
            #expect(GameCovers.asset(value, appID: 12345) == nil)
        }
    }
    @Test func heyboxWebpPathsAreUsedDirectlyWithoutSteamMetadataRoundtrip() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), calls = CoverRequests()
        let urls = ["https://heyboxbj.max-c.com/gameimg/steam_item_assets/hash-only.jpg?imageMogr2/thumbnail/460x215%3E/format/webp", "https://cdn.max-c.com/heybox/game/header/12346_test.jpg"]
        let store = GameCovers(cache: root, fetch: { url in await calls.record(url); return image }, metadata: { _ in Issue.record("Chart image should not query Steam metadata"); return nil })
        for (offset, raw) in urls.enumerated() {
            #expect(GameCovers.candidates(appID: 12345+offset, reference: raw).map(\.absoluteString) == [raw])
            #expect(try await store.load(appID: 12345+offset, reference: raw) == image)
        }
        #expect(await calls.urls.count == 2)
        #expect(GameCovers.asset("https://cdn.max-c.com.evil.example/heybox/game/header/a.jpg", appID: 12345) == nil)
        #expect(GameCovers.asset("https://cdn.max-c.com/private/a.jpg", appID: 12345) == nil)
    }
    @Test func rejectsHtmlAndFallsBackAcrossCdns() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), calls = CoverRequests()
        let store = GameCovers(cache: root, fetch: { url in
            await calls.record(url)
            return url.host == "shared.fastly.steamstatic.com" ? image : Data("<html>not an image</html>".utf8)
        }, metadata: { _ in Issue.record("Known asset fallback should not query metadata"); return nil })
        let result = try await store.load(appID: 12345, reference: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/12345/hash/header_schinese.jpg?t=42")
        #expect(result == image); #expect(await calls.urls.count == 2)
        #expect(try FileStore.read(root.appendingPathComponent("12345.image")) == image)
        #expect(!GameCovers.validImage(Data([0xff,0xd8,0xff])))
    }
    @Test func resolvesFreshStoreAssetWhenOldUrlIsMissing() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), calls = CoverRequests()
        let reference = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/12345/new-hash/header_schinese.jpg?t=99"
        let store = GameCovers(cache: root, fetch: { url in
            await calls.record(url)
            if url.path.contains("new-hash") { return image }; throw HTTPStatusFailure(status: 404, retryAfter: nil)
        }, metadata: { id in #expect(id == 12345); return reference })
        #expect(try await store.load(appID: 12345, reference: "https://cdn.akamai.steamstatic.com/steam/apps/12345/header.jpg") == image)
        #expect(await calls.urls.last?.absoluteString == reference)
    }
    @Test func coalescesLoadsAndReusesDiskCacheOffline() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), calls = CoverRequests(), reference = "https://shared.akamai.steamstatic.com/steam/apps/12345/header.jpg"
        let store = GameCovers(cache: root, fetch: { url in await calls.record(url); try await Task.sleep(for: .milliseconds(50)); return image }, metadata: { _ in nil })
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<12 { group.addTask { try await store.load(appID: 12345, reference: reference) } }
            for try await data in group { #expect(data == image) }
        }
        #expect(await calls.urls.count == 1)
        let offline = GameCovers(cache: root, fetch: { _ in Issue.record("Valid disk cache should avoid network"); throw AppFailure("offline") }, metadata: { _ in Issue.record("Unexpected metadata"); return nil })
        #expect(try await offline.load(appID: 12345, reference: reference) == image)
    }
    @Test func localSteamArtworkWorksWithoutNetworkAndIsNotModified() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), steam = root.appendingPathComponent("Steam"), file = steam.appendingPathComponent("appcache/librarycache/12345/hash_header.jpg")
        try FileStore.write(image, to: file)
        let store = GameCovers(cache: root.appendingPathComponent("Covers"), fetch: { _ in Issue.record("Unexpected network"); throw AppFailure("offline") }, metadata: { _ in Issue.record("Unexpected metadata"); return nil })
        #expect(try await store.load(appID: 12345, steam: steam) == image)
        #expect(try FileStore.read(file) == image)
    }
    @Test func nestedSteamHeaderSurvivesRemovalAndCacheClearing() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let cache = paths.cache.appendingPathComponent("Covers"), archive = SaveGameMetadataStore.covers(paths)
        let image = try png()
        let file = paths.steam.appendingPathComponent("appcache/librarycache/5175310/" + String(repeating: "a", count: 40) + "/library_header_schinese.jpg")
        try FileStore.write(image, to: file)
        let store = GameCovers(cache: cache, archive: archive)
        #expect(try await store.load(appID: 5175310, steam: paths.steam) == image)
        try await store.retainCached(appID: 5175310, steam: paths.steam)
        try FileStore.fm.removeItem(at: file)
        _ = try CacheMaintenance.clear(paths: paths)
        let restarted = GameCovers(cache: cache, archive: archive)
        #expect(await restarted.cachedImage(appID: 5175310, steam: paths.steam) == image)
        #expect(await restarted.cachedImage(appID: 480, steam: paths.steam) == nil)
    }

    @Test func failuresAreNotCachedAsImagesAndExplicitRetryRecovers() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), calls = CoverRequests()
        let store = GameCovers(cache: root, fetch: { url in await calls.record(url); if await calls.available { return image }; throw URLError(.notConnectedToInternet) }, metadata: { _ in nil })
        await #expect(throws: (any Error).self) { try await store.load(appID: 12345) }
        let count = await calls.urls.count
        #expect(!FileStore.fm.fileExists(atPath: root.appendingPathComponent("12345.image").path))
        await #expect(throws: (any Error).self) { try await store.load(appID: 12345) }
        #expect(await calls.urls.count == count)
        await calls.enable()
        #expect(try await store.load(appID: 12345, force: true) == image)
        #expect(await calls.urls.count == count+1)
    }
    @Test func cachedArtworkIsAvailableImmediatelyWhenAViewChangesImageSource() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png()
        let first = GameCovers(cache: root, fetch: { _ in image }, metadata: { _ in nil })
        _ = try await first.load(appID: 12345, reference: "https://shared.akamai.steamstatic.com/steam/apps/12345/header.jpg")
        let offline = GameCovers(cache: root, fetch: { _ in Issue.record("Immediate cache lookup must not fetch"); throw URLError(.notConnectedToInternet) }, metadata: { _ in nil })
        #expect(await offline.cachedImage(appID: 12345) == image)
        #expect(await offline.cachedImage(appID: 12346) == nil)
    }
    @Test func corruptCacheIsReplacedAndConcurrentDownloadsAreBounded() async throws {
        let root = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let image = try png(), calls = CoverRequests()
        try FileStore.write(Data("<html>broken cache</html>".utf8), to: root.appendingPathComponent("12345.image"))
        let store = GameCovers(cache: root, fetch: { url in
            await calls.begin(url); try await Task.sleep(for: .milliseconds(20)); await calls.end(); return image
        }, metadata: { _ in nil })
        try await withThrowingTaskGroup(of: Data.self) { group in
            for id in 12345..<12355 { group.addTask { try await store.load(appID: id) } }
            for try await data in group { #expect(data == image) }
        }
        #expect(await calls.maximum <= 4); #expect(await calls.urls.count == 10)
        #expect(try FileStore.read(root.appendingPathComponent("12345.image")) == image)
    }
}
