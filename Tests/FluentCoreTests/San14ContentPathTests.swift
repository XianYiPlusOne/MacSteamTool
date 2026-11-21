import Foundation
import Testing
@testable import FluentCore

/// Offline reproduction using public depot IDs and synthetic keys only.
@Suite struct San14ContentPathTests {
    let app = 872410
    let placeholder = String(repeating: "ab", count: 32)
    func metadata() -> AppInfo {
        AppInfo(id: app, dictionary: ["common": ["name": "SAN14 fixture", "oslist": "windows"],
            "depots": Dictionary(uniqueKeysWithValues: (872411...872415).map {
                (String($0), ["manifests": ["public": ["gid": String($0), "size": $0 == 872415 ? "0" : "100"]]])
            })])
    }
    @Test func missingDepotRemainsMissingThroughLuaAndUpstreamConfiguration() async throws {
        let keys = Dictionary(uniqueKeysWithValues: (872411...872414).map { ($0, placeholder) })
        let result = try await AutomaticLibraryImport.resolve(appID: app, includeDLC: false,
            appInfo: { _ in metadata() }, cachedKeys: { keys }, refreshKeys: { keys },
            remote: { [ImportFile(name: "872410.lua", data: Data("addappid(872410)".utf8))] })
        #expect(!result.complete)
        #expect(result.warnings.contains { $0.contains("872415") })
        let doc = try LuaDocument.parse(String(decoding: result.files[0].data, as: UTF8.self))
        #expect(doc.depots.count == 4)
        var config = MacSteamConfig(); try config.merge(doc)
        let roundtrip = try MacSteamConfig.parse(config.serialized())
        #expect(roundtrip.keys[app]?[872415] == nil)
        #expect(roundtrip.keys[app]?.count == 4)
    }
    @Test func authorizedExtractionPreservesDepotOwnerAndCanFillMissingDepot() async throws {
        let json: [String: Any] = ["ok": true, "appID": app, "name": "SAN14 fixture", "accessToken": "0",
            "depots": [["id": 872415, "owner": app, "sourceApp": app, "key": placeholder,
                        "result": "OK", "manifest": "2940628593678107107"]]]
        let response = try JSONDecoder().decode(SteamEngineResponse.self, from: JSONSerialization.data(withJSONObject: json))
        let doc = try LuaDocument.parse(response.lua())
        #expect(doc.depots.first?.owner == app)
        var config = MacSteamConfig(); try config.merge(doc)
        #expect(try MacSteamConfig.parse(config.serialized()).keys[app]?[872415] == placeholder)
        // Cached manifest availability is independent of possessing a key.
        #expect(doc.pins.contains { $0.depot == 872415 && $0.active })
        let keys = Dictionary(uniqueKeysWithValues: (872411...872415).map { ($0, placeholder) })
        let completed = try await AutomaticLibraryImport.resolve(appID: app, includeDLC: false,
            appInfo: { _ in metadata() }, cachedKeys: { keys }, refreshKeys: { Issue.record("No refresh needed"); return [:] }, remote: { [] })
        #expect(completed.complete)
    }
}
