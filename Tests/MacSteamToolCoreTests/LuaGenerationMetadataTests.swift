import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct LuaGenerationMetadataTests {
    @Test func completeDLCMergesExistingLuaAndOnlyQueriesMissingDepots() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = String(repeating: "ab", count: 32)
        try FileStore.json(["101": key, "201": key], to: folder.appendingPathComponent("depotkeys.json"))
        let old = folder.appendingPathComponent("100.lua")
        try FileStore.write(Data("addappid(100)\naddtoken(100, \"9\")\n".utf8), to: old)
        let source = LuaGenerationMetadata(includeDLC: true, publicInfo: { id in
            if id == 100 {
                return AppInfo(id: id, dictionary: ["extended": ["listofdlc": "200,300"],
                                                     "depots": ["101": ["manifests": ["public": ["gid": "3"]]]]])
            }
            if id == 200 { throw AppFailure("Public app info unavailable") }
            return AppInfo(id: id, dictionary: ["common": ["type": "DLC"]])
        }, steam: { ids, missing in
            if ids == [100] {
                #expect(missing.isEmpty)
                return [SteamGenerationApp(id: 100, accessToken: "10", productInfo: nil)]
            }
            #expect(ids == [200, 300])
            #expect(missing == [200, 300])
            return [SteamGenerationApp(id: 200, accessToken: String(UInt64.max),
                                       productInfo: #"{"depots":{"201":{"manifests":{"public":{"gid":"4"}}}}}"#)]
        })
        let service = ContentService(api: SteamAPI(cache: folder), cache: folder)
        let result = try await service.generate(id: 100, includeDLC: true, preferences: Preferences(),
                                                metadata: source, appendingTo: old) { _ in }
        let doc = try LuaDocument.parse(result.lua)
        #expect(doc.tokens == [100: "9", 200: String(UInt64.max)])
        #expect(doc.dlcIDs == [200, 300])
        #expect(doc.depots.map(\.id) == [101, 201])
        #expect(result.lua.components(separatedBy: "addtoken(100,").count == 2)
    }

    @Test func unavailableSteamPreservesPublicMetadataAndCancellationPropagates() async throws {
        let publicInfo: LuaGenerationMetadata.PublicLookup = { AppInfo(id: $0, dictionary: ["common": ["name": "Public"]]) }
        let source = LuaGenerationMetadata(includeDLC: false, publicInfo: publicInfo, steam: { _, _ in throw AppFailure("Offline") })
        #expect(try await source.appInfo(100).name == "Public")
        #expect(await source.notices.count == 1)
        #expect(try await source.addingTokens(to: "addappid(100)") == "addappid(100)")
        let cancelled = LuaGenerationMetadata(includeDLC: false, publicInfo: publicInfo, steam: { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.appInfo(100) }
    }
}
