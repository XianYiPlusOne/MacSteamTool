import Foundation
import Testing
@testable import FluentCore

@Suite struct RuntimeFeatureTests {
    @Test func automaticPresenceDefaultPreservesExplicitChoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        #expect(try RuntimeFeatures.load(paths: paths).presence == .automatic)
        var config = RuntimeFeatures(); try config.save(paths: paths)
        #expect(try RuntimeFeatures.load(paths: paths).presence == .automatic)
        for mode in [FriendPresence.none, .unchanged, .selected] {
            config.presence = mode; config.presenceApps = ["480": "Spacewar"]; try config.save(paths: paths)
            let value = try RuntimeFeatures.load(paths: paths)
            #expect(value.presence == mode); #expect(value.presenceApps["480"] == "Spacewar")
        }
    }
    @Test func legacySpacewarModeMigratesWithoutChangingSelectedApps() throws {
        let decoder = JSONDecoder()
        let config = try decoder.decode(RuntimeFeatures.self, from: Data(#"{"presence":"spacewar","presenceApps":{"4348910":"深空当铺"},"tickets":{}}"#.utf8))
        #expect(config.presence == .selected)
        #expect(config.presenceApps == ["4348910": "深空当铺"])
        let encoded = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["presence"] as? String == "selected")
        #expect(throws: (any Error).self) { try decoder.decode(FriendPresence.self, from: Data(#""unknown""#.utf8)) }
    }
    @Test func luaAccessTokensRoundTripAndDisable() throws {
        let doc = try LuaDocument.parse("addappid(480)\naddtoken(480, \"18446744073709551615\")\naddappid(481)\naddtoken(481, \"7\")\n")
        var config = MacSteamConfig(); try config.merge(doc)
        let loaded = try MacSteamConfig.parse(config.serialized())
        #expect(loaded.accessTokens[480] == String(UInt64.max)); #expect(loaded.accessTokens[481] == "7")
        #expect(try LuaDocument.parse(loaded.lua(for: 480)).tokens == doc.tokens)
        config.remove(480); #expect(config.accessTokens.isEmpty)
        #expect(throws: (any Error).self) { try LuaDocument.parse("addappid(480)\naddtoken(480, \"18446744073709551616\")") }
        #expect(throws: (any Error).self) { try LuaDocument.parse("addappid(480)\naddtoken(480, \"1\")\naddtoken(480, \"2\")") }
        #expect(throws: (any Error).self) { try MacSteamConfig.parse("FluentAccessTokens:\n  480: 1\n  480: 2\n") }
        try config.merge(try LuaDocument.parse("addappid(480)\naddtoken(480, \"0\")")); #expect(config.accessTokens.isEmpty)
    }
    func ticket() throws -> CachedSteamTicket {
        var own = Data(repeating: 0, count: 178)
        own[0] = 50; own[8] = 1; own[12] = 1; own[14] = 0x10; own[15] = 1; own[16] = 0xe0; own[17] = 1
        return try CachedSteamTicket(appID: 480, ownership: own, encrypted: Data([8, 1, 18, 1, 0]))
    }
    @Test func originalTicketTextAndBinaryRoundTrip() throws {
        let t = try ticket()
        let text = "appid:480\nappticket(178bytes):\(t.ownership)\neticket(5bytes):\(t.encrypted)\n"
        let imported = try CachedSteamTicket.parse(text)
        #expect(imported.appID == 480); #expect(imported.steamID == 76561197960265729)
        #expect(!imported.enabled); #expect(imported.ownership == t.ownership)
        #expect(throws: (any Error).self) { try CachedSteamTicket.parse(text.replacingOccurrences(of: "appid:480", with: "appid:481")) }
        #expect(throws: (any Error).self) { try CachedSteamTicket.decodeHex("0x34") }
        var corrupt = try CachedSteamTicket.decodeHex(t.ownership); corrupt[0] = 49
        #expect(throws: (any Error).self) { try CachedSteamTicket(appID: 480, ownership: corrupt, encrypted: Data([1])) }
    }
    @Test func runtimeSettingsPrivateAndRemovalPreservesPresence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        var c = RuntimeFeatures(); c.tickets["480"] = try ticket(); c.presence = .none; c.presenceApps = ["480": "Spacewar"]
        try c.save(paths: paths)
        let attrs = try FileManager.default.attributesOfItem(atPath: RuntimeFeatures.url(paths: paths).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var read = try RuntimeFeatures.load(paths: paths); #expect(read.tickets["480"]?.appID == 480)
        read.tickets.removeValue(forKey: "480"); try read.save(paths: paths)
        let final = try RuntimeFeatures.load(paths: paths)
        #expect(final.tickets.isEmpty); #expect(final.presence == .none); #expect(final.presenceApps["480"] == "Spacewar")
    }
    @Test func statisticsDoNotEnableSaveRedirection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        var c = CloudConfiguration(); c.syncPlaytime = true
        #expect(throws: (any Error).self) { try c.save(paths: paths) }
        c.statsApps = "480"; try c.save(paths: paths)
        let read = try CloudConfiguration.load(paths: paths)
        #expect(!read.enabled); #expect(read.apps.isEmpty); #expect(read.statsApps == "480"); #expect(read.syncPlaytime); #expect(!read.syncAchievements)
    }
}
