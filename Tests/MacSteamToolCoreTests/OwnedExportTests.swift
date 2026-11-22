import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct OwnedExportTests {
    func response() throws -> SteamEngineResponse {
        let key = String(repeating: "a", count: 64)
        let json: [String: Any] = ["ok": true, "appID": 100, "name": "Root", "accessToken": "18446744073709551615",
            "extractedApps": [["id": 100, "name": "Root", "accessToken": "18446744073709551615"], ["id": 200, "name": "DLC\nname", "accessToken": "22"], ["id": 400, "name": "Depotless", "accessToken": "0"]],
            "depots": [["id": 101, "owner": 100, "sourceApp": 100, "key": key, "result": "OK", "manifest": "18446744073709551615"], ["id": 201, "owner": 200, "sourceApp": 900, "key": key, "result": "OK", "manifest": "123"], ["id": 202, "owner": 200, "sourceApp": 200, "key": "", "result": "AccessDenied", "manifest": "456"]], "warnings": ["Missing DLC metadata"]]
        return try JSONDecoder().decode(SteamEngineResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }
    @Test func exportedLuaOwnershipAndUInt64() throws {
        let result = try response(), lua = try result.lua(), document = try LuaDocument.parse(lua)
        #expect(document.appID == 100)
        #expect(Set(document.dlcIDs) == [200,400])
        #expect(!lua.contains("addappid(900)")); #expect(!lua.contains("setManifestid(202"))
        #expect(lua.contains("addtoken(200, \"22\")")); #expect(lua.contains("18446744073709551615"))
        #expect(lua.contains("addappid(200) -- DLC name")); #expect(result.depots?[1].sourceApp == 900)
        var bad = result; bad.extractedApps?.append(result.extractedApps![0])
        #expect(throws: (any Error).self) { try bad.lua() }
        bad = result; bad.depots?[0].owner = 0
        #expect(throws: (any Error).self) { try bad.lua() }
    }
    @Test func schemaExportIsOptionalAndNeverCopiesAccountState() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let stats = root.appendingPathComponent("appcache/stats"), schema = stats.appendingPathComponent("UserGameStatsSchema_100.bin"), user = stats.appendingPathComponent("UserGameStats_123_100.bin")
        try FileStore.write(Data("account state must stay unchanged".utf8), to: user)
        let result = try response()
        #expect(try OwnedExport.files(result, steam: root, includeSchema: false).files.count == 1)
        let missing = try OwnedExport.files(result, steam: root, includeSchema: true)
        #expect(missing.files.count == 1); #expect(missing.warnings.count == 2)
        try FileStore.write(Data([0,1,2,3]), to: schema)
        let exported = try OwnedExport.files(result, steam: root, includeSchema: true)
        #expect(exported.files.map(\.name) == ["100.lua", "UserGameStatsSchema_100.bin"])
        #expect(exported.files[1].data == Data([0,1,2,3]))
        #expect(try FileStore.text(user) == "account state must stay unchanged")
        try FileStore.fm.removeItem(at: schema); try FileStore.fm.createSymbolicLink(at: schema, withDestinationURL: user)
        #expect(throws: (any Error).self) { try OwnedExport.files(result, steam: root, includeSchema: true) }
    }
    @Test func importDeduplicationAndExtensionNormalization() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let first = root.appendingPathComponent("a/100.LUA"), second = root.appendingPathComponent("b/100.lua")
        try FileStore.write(Data("addappid(100)".utf8), to: first); try FileStore.write(FileStore.read(first), to: second)
        #expect(try ArchiveIO.importFiles([first,second]).map(\.name) == ["100.lua"])
        try FileStore.write(Data("addappid(200)".utf8), to: second)
        #expect(throws: (any Error).self) { try ArchiveIO.importFiles([first,second]) }
    }
}
