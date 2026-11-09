import Foundation
import Testing
@testable import FluentCore

struct OfflineSchemaTests {
    @Test func numericDefinitionsKeepTypesDefaultsAndExcludeUserValues() throws {
        let data = Data(#"{"game":{"availableGameStats":{"stats":[{"name":"int","type":"int","defaultvalue":-3,"value":999},{"name":"float","type":"float","defaultvalue":3.5},{"name":"rate","type":"avgrate","defaultvalue":"0"}]}}}"#.utf8)
        let schema = try OfflineSchema.parse(data)
        let rows = try #require(JSONSerialization.jsonObject(with: schema.statsJSON()) as? [[String: String]])
        #expect(rows.map { $0["type"]! } == ["int", "float", "avgrate"])
        #expect(rows[0]["default"] == "-3"); #expect(rows[0]["value"] == nil)
        for value in ["NaN", "Infinity", "2147483648", "1.5"] {
            let invalid = try JSONSerialization.data(withJSONObject: ["game": ["availableGameStats": ["stats": [["name": "bad", "type": "int", "defaultvalue": value]]]]])
            #expect(throws: (any Error).self) { try OfflineSchema.parse(invalid) }
        }
    }
    @Test func localBinarySchemaRequiresMatchingAppAndGeneratesStatistics() throws {
        func text(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }
        var bytes: [UInt8] = [0] + text("100") + [0] + text("stats") + [0] + text("1")
        bytes += [1] + text("name") + text("distance")
        bytes += [2] + text("type_int") + [2, 0, 0, 0]
        bytes += [3] + text("default") + [0, 0, 96, 64] + [8, 8, 8, 8]
        let result = try OfflineSchema.fromBinary(Data(bytes), appID: 100, language: "schinese")
        #expect(result.statistics.count == 1); #expect(result.statistics[0].type == "float"); #expect(result.statistics[0].default == "3.5")
        #expect(throws: (any Error).self) { try OfflineSchema.fromBinary(Data(bytes), appID: 101, language: "english") }
        #expect(throws: (any Error).self) { try VDF.binary(Data(bytes.dropLast(3))) }
    }
    @Test func combinedOfflineInstallAndRestoreUseOneReceipt() throws {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OfflineCombined-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let p = AppPaths(home: root, data: root.appendingPathComponent("Data")), game = root.appendingPathComponent("Game").standardizedFileURL
        try FileStore.write(Data("original exe".utf8), to: game.appendingPathComponent("Game.exe"))
        try FileStore.write(Data("original api".utf8), to: game.appendingPathComponent("steam_api64.dll"))
        let a = root.appendingPathComponent("Unpacked"), b = root.appendingPathComponent("Goldberg")
        try FileStore.write(Data("unpacked exe".utf8), to: a.appendingPathComponent("Game.exe"))
        try FileStore.write(Data("new api".utf8), to: b.appendingPathComponent("steam_api64.dll"))
        try FileStore.write(Data("[]".utf8), to: b.appendingPathComponent("steam_settings/stats.json"))
        let plan = try OfflineTools.combined([GamePatches.plan(package: a, gameRoot: game, appID: 100), GamePatches.plan(package: b, gameRoot: game, appID: 100)])
        let receipt = try GamePatches.install(plan, paths: p)
        #expect(receipt.deployed.count == 3); #expect(GamePatches.receipts(paths: p).count == 1)
        try GamePatches.restore(receipt, paths: p)
        #expect(try FileStore.text(game.appendingPathComponent("Game.exe")) == "original exe")
        #expect(try FileStore.text(game.appendingPathComponent("steam_api64.dll")) == "original api")
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("steam_settings/stats.json").path))
    }
    @Test func definitionsRetainHiddenNamesButNeverPlayerUnlocks() throws {
        let input = Data(#"{"game":{"availableGameStats":{"achievements":[{"name":"A/../B","displayName":"Hidden title","description":"Detail","hidden":1,"achieved":1,"unlocktime":42,"icon":"http://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/480/a.jpg","icongray":"https://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/480/b.jpg"}]}}}"#.utf8)
        var schema = try OfflineSchema.parse(input)
        let path = try #require(OfflineSchema.imagePath(schema.definitions[0].icon))
        #expect(!path.contains("..")); #expect(path.hasPrefix("achievement_images/"))
        #expect(OfflineSchema.imageURL(schema.definitions[0].icon)?.scheme == "https")
        schema.images[path] = Data([1,2,3])
        let rows = try #require(JSONSerialization.jsonObject(with: schema.json()) as? [[String: Any]])
        #expect(rows[0]["name"] as? String == "A/../B")
        #expect(rows[0]["hidden"] as? Int == 1)
        #expect(rows[0]["icon"] as? String == path)
        #expect(rows[0]["icon_gray"] == nil)
        #expect(rows[0]["achieved"] == nil); #expect(rows[0]["unlocktime"] == nil)
    }
    @Test func malformedSchemasAndUntrustedImageLocationsAreRejected() throws {
        for raw in [#"{}"#, #"{"game":{"availableGameStats":{"achievements":"broken"}}}"#, #"{"game":{"availableGameStats":{"achievements":[{"name":"A"},{"name":"A"}]}}}"#] {
            #expect(throws: (any Error).self) { try OfflineSchema.parse(Data(raw.utf8)) }
        }
        #expect(try OfflineSchema.parse(Data(#"{"game":{"availableGameStats":{}}}"#.utf8)).definitions.isEmpty)
        for raw in ["file:///tmp/a.png", "https://steamstatic.com.evil.test/a.png", "https://user:secret@steamstatic.com/a.png", "https://steamstatic.com:8443/a.png", "https://steamstatic.com/a.exe"] {
            #expect(OfflineSchema.imagePath(raw) == nil)
        }
    }
}
