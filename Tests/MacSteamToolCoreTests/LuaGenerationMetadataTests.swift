import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct LuaGenerationMetadataTests {
    @Test func appendingPublicMetadataPreservesExistingLocalToken() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = String(repeating: "ab", count: 32)
        try FileStore.json(["101": key, "201": key], to: folder.appendingPathComponent("depotkeys.json"))
        let old = folder.appendingPathComponent("100.lua")
        try FileStore.write(Data("addappid(100)\naddtoken(100, \"9\")\n".utf8), to: old)
        let service = ContentService(api: SteamAPI(cache: folder), cache: folder)
        let result = try await service.generate(id: 100, includeDLC: true, preferences: Preferences(), appInfo: { id in
            AppInfo(id: id, dictionary: ["depots": ["101": ["manifests": ["public": ["gid": "3"]]]]])
        }, appendingTo: old) { _ in }
        let doc = try LuaDocument.parse(result.lua)
        #expect(doc.tokens == [100: "9"])
        #expect(result.lua.components(separatedBy: "addtoken(100,").count == 2)
    }
}
