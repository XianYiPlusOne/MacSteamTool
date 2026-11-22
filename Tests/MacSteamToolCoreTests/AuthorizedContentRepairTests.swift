import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct AuthorizedContentRepairTests {
    let key = String(repeating: "ab", count: 32)
    func response(result: String = "OK", key: String? = nil, app: Int = 872410, owner: Int = 872410, duplicate: Bool = false) throws -> SteamEngineResponse {
        let depot: [String: Any] = ["id": 872415, "owner": owner, "sourceApp": 872410, "key": key ?? self.key, "result": result, "manifest": "2940628593678107107"]
        return try JSONDecoder().decode(SteamEngineResponse.self, from: JSONSerialization.data(withJSONObject: ["ok": true, "appID": app, "depots": duplicate ? [depot, depot] : [depot]]))
    }
    @Test func mergesOnlyRequestedContentWithoutPinsAndPreservesDLC() throws {
        let original = "addappid(872410) -- SAN14\naddappid(872411, 1, \"KEY\")\naddappid(490) -- DLC\n".replacingOccurrences(of: "KEY", with: key)
        let doc = try LuaDocument.parse(original)
        let file = try AuthorizedContentRepair.prepare(document: doc, missing: [872415], response: response())
        let text = String(decoding: file.data, as: UTF8.self), merged = try LuaDocument.parse(text)
        #expect(text.hasPrefix(original))
        #expect(merged.depots.first { $0.id == 872415 }?.owner == 872410)
        #expect(merged.dlcIDs == [490])
        #expect(!text.contains("setManifestid"))
        #expect(merged.depots.count == 2)
    }
    @Test func denialMalformedDuplicateAndWrongAppCannotProduceRepair() throws {
        let doc = try LuaDocument.parse("addappid(872410)")
        for response in [try response(result: "AccessDenied"), try response(key: "bad"), try response(app: 480), try response(owner: 480), try response(duplicate: true)] {
            #expect(throws: (any Error).self) { try AuthorizedContentRepair.prepare(document: doc, missing: [872415], response: response) }
        }
        #expect(throws: (any Error).self) { try AuthorizedContentRepair.prepare(document: doc, missing: [872415, 872416], response: response()) }
    }
}
