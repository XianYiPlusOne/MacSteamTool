import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct ParityTests {
    func ticket(offset: Int, descriptor: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 220)
        func put(_ value: UInt32, at: Int) { for i in 0..<4 { data[at+i] = UInt8(truncatingIfNeeded: value >> (8*i)) } }
        put(UInt32(descriptor ? offset : 92), at: 0); if descriptor { put(4, at: 4) }
        data[8] = 1; data[12] = 1; data[14] = 0x10; data[15] = 1
        put(480, at: offset); return data
    }
    @Test func descriptorUnalignedAndConservativeScanning() throws {
        for (offset, descriptor) in [(16, false), (50, true), (51, false)] {
            let value = try CachedSteamTicket(appID: 480, ownership: ticket(offset: offset, descriptor: descriptor), encrypted: Data([1]))
            #expect(value.appIDOffset == offset); #expect(value.signatureOffset == 92); #expect(value.appID == 480)
            let decoded = try JSONDecoder().decode(CachedSteamTicket.self, from: JSONEncoder().encode(value))
            try decoded.validate(appID: 480)
        }
        var ambiguous = ticket(offset: 50); ambiguous[60] = 0xe0; ambiguous[61] = 1
        #expect(throws: (any Error).self) { try CachedSteamTicket(appID: 480, ownership: ambiguous, encrypted: Data([1])) }
        for offset in [0, 8, 90, 100] {
            #expect(throws: (any Error).self) { try CachedSteamTicket(appID: 480, ownership: ticket(offset: offset, descriptor: true), encrypted: Data([1])) }
        }
        var zeroAccount = ticket(offset: 50, descriptor: true); zeroAccount.replaceSubrange(8..<16, with: repeatElement(UInt8(0), count: 8))
        #expect(throws: (any Error).self) { try CachedSteamTicket(appID: 480, ownership: zeroAccount, encrypted: Data([1])) }
        #expect(throws: (any Error).self) { try CachedSteamTicket(appID: 481, ownership: ticket(offset: 50, descriptor: true), encrypted: Data([1])) }
    }
    @Test func batchesAreAtomicAndRestorable() throws {
        let home = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: home) }
        let paths = AppPaths(home: home), service = LibraryService(paths: paths)
        try service.perform(service.plan([ImportFile(name: "480.lua", data: Data("addappid(480)".utf8)), ImportFile(name: "490.lua", data: Data("addappid(490)".utf8))]))
        let initial = try FileStore.read(paths.config), games = try SteamLibrary.games(paths)
        try service.batch(games, action: .disable)
        #expect(try SteamLibrary.games(paths).allSatisfy { !$0.enabled })
        #expect(try FileStore.text(paths.disabled.appendingPathComponent("480.lua")) == "addappid(480)")
        try service.batch(SteamLibrary.games(paths), action: .enable)
        #expect(try MacSteamConfig.parse(FileStore.text(paths.config)).apps == MacSteamConfig.parse(String(decoding: initial, as: UTF8.self)).apps)
        // A failure in the second Lua must leave the first and config untouched.
        let before = try FileStore.read(paths.config), first = try FileStore.read(paths.lua.appendingPathComponent("480.lua"))
        try FileStore.write(Data("not valid lua".utf8), to: paths.lua.appendingPathComponent("490.lua"))
        #expect(throws: (any Error).self) { try service.batch(games.sorted { $0.id < $1.id }, action: .disable) }
        #expect(try FileStore.read(paths.config) == before); #expect(try FileStore.read(paths.lua.appendingPathComponent("480.lua")) == first)
        try FileStore.write(Data("addappid(490)".utf8), to: paths.lua.appendingPathComponent("490.lua"))
        try service.batch(games, action: .remove)
        #expect(try SteamLibrary.games(paths).isEmpty)
        let record = try #require(FileTransaction(backupRoot: paths.backups).records().first)
        try service.restoreBackup(record)
        #expect(try SteamLibrary.games(paths).count == 2)
        #expect(throws: (any Error).self) { try service.batch([Game(id: 1, name: "Native", source: "Steam")], action: .remove) }
    }
    @Test func remotePackagePreviewRejectsWrongAppAndInvalidLink() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(root); defer { try? FileStore.fm.removeItem(at: root) }
        let engine = URL(fileURLWithPath: "/missing-engine")
        for app in [480, 490] {
            let archive = root.appendingPathComponent("\(app).zip")
            try ArchiveIO.export([ImportFile(name: "\(app).lua", data: Data("addappid(\(app))".utf8))], to: archive)
            let data = try FileStore.read(archive)
            if app == 480 {
                let files = try await RemoteLuaPackage.extract(data, appID: 480, engine: engine)
                #expect(files.count == 1); #expect(files.first?.name == "480.lua")
                let plan = try LibraryService(paths: AppPaths(home: root)).plan(files)
                #expect(plan.documents.first?.appID == 480)
            } else {
                await #expect(throws: (any Error).self) { try await RemoteLuaPackage.extract(data, appID: 480, engine: engine) }
            }
        }
        await #expect(throws: (any Error).self) { try await RemoteLuaPackage.extract(Data("<html>error</html>".utf8), appID: 480, engine: engine) }
        let url = try RemoteLuaPackage.proxyURL(Data(#"{"short_code":"abc_123"}"#.utf8))
        #expect(url.absoluteString == "https://short.walftech.com/proxy.php?short=abc_123")
        #expect(throws: (any Error).self) { try RemoteLuaPackage.proxyURL(Data(#"{"short_code":"../evil?x=1"}"#.utf8)) }
    }
    @Test func hubExpiryRejectionAndRetryWithoutNetwork() async throws {
        let now = Date(), credential = ManifestHubCredential(key: "secret+with/slash", saved: Date())
        #expect(credential.expiry.timeIntervalSince(credential.saved) == 86400)
        let calls = AttemptCounter()
        await #expect(throws: (any Error).self) {
            _ = try await ManifestHub.fetch(depot: 481, manifest: "1", credential: credential, now: now.addingTimeInterval(90000), download: { _ in await calls.next(); return Data() })
        }
        #expect(await calls.count == 0)
        await #expect(throws: (any Error).self) {
            _ = try await ManifestHub.fetch(depot: 481, manifest: "1", credential: credential, download: { url in
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "apikey" }?.value == credential.key)
                await calls.next(); throw HTTPStatusFailure(status: 403, retryAfter: nil)
            })
        }
        #expect(await calls.count == 1)
        let retries = AttemptCounter()
        await #expect(throws: (any Error).self) {
            _ = try await ManifestHub.fetch(depot: 481, manifest: "1", credential: credential, download: { _ in await retries.next(); throw HTTPStatusFailure(status: 429, retryAfter: 1) }, delay: { _ in })
        }
        #expect(await retries.count == 4)
        await #expect(throws: (any Error).self) {
            _ = try await ManifestHub.fetch(depot: 481, manifest: "1", credential: credential, download: { _ in Data("<html>wrong manifest</html>".utf8) })
        }
    }
}
private actor AttemptCounter {
    var count = 0
    @discardableResult func next() -> Int { count += 1; return count }
}
