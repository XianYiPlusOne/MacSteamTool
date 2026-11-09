import Foundation
import Testing
@testable import FluentCore
struct CacheMaintenanceTests {
    @Test func onlyDisposableCacheIsClearedAndCustomGamePathsAreProtected() throws {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CacheTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        var p = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        for name in ["Metadata/a", "Tools/a", "OfflineStages/a"] { try FileStore.write(Data("cache".utf8), to: p.cache.appendingPathComponent(name)) }
        try FileStore.write(Data("save".utf8), to: p.data.appendingPathComponent("CloudSaves/a"))
        #expect(try CacheMaintenance.summary(paths: p).entries == 2)
        #expect(try CacheMaintenance.clear(paths: p).bytes == 10)
        #expect(try FileStore.text(p.cache.appendingPathComponent("Tools/a")) == "cache")
        #expect(try FileStore.text(p.data.appendingPathComponent("CloudSaves/a")) == "save")
        p.lua = p.cache.appendingPathComponent("Metadata/Lua")
        try FileStore.write(Data("lua".utf8), to: p.lua.appendingPathComponent("100.lua"))
        #expect(throws: (any Error).self) { try CacheMaintenance.clear(paths: p) }
        #expect(try FileStore.text(p.lua.appendingPathComponent("100.lua")) == "lua")
    }
    @Test func manifestTemplatesUseManifestIdentityAndCDNRejectsHTML() {
        for source in DownloadSources.manifestTemplates { #expect(source.contains("{manifest}")); #expect(source.hasPrefix("https://")) }
        #expect(DownloadSources.validImage(Data([0xff, 0xd8, 0xff, 0x00])))
        #expect(!DownloadSources.validImage(Data("<html>gateway failure</html>".utf8)))
    }
}
