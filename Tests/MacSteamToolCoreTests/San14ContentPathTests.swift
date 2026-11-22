import Foundation
import Testing
@testable import MacSteamToolCore

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
}
