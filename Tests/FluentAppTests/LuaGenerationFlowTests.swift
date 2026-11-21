import Foundation
import Testing
@testable import FluentCore
@testable import FluentSteam

@Suite @MainActor struct LuaGenerationFlowTests {
    @Test func automaticImportUsesProtectedDepotsAndScopedAppTokens() async throws {
        let (root, model) = try AutomaticLibraryFlowTests().fixture()
        defer { try? FileStore.fm.removeItem(at: root) }
        let key = String(repeating: "ab", count: 32)
        model.libraryKeyFetch = { _ in [101: key, 201: key] }
        model.remotePackageFetch = { _, _, _ in Issue.record("Unexpected remote package"); return [] }
        model.libraryInfoFetch = { id in
            if id == 100 {
                return AppInfo(id: id, dictionary: ["common": ["name": "Root"], "extended": ["listofdlc": "300"]])
            }
            #expect(id == 200)
            return AppInfo(id: id, dictionary: ["common": ["type": "DLC"],
                "depots": ["201": ["manifests": ["public": ["gid": "2"]]]]])
        }
        model.generationSteamFetch = { ids, missing in
            if ids == [100] {
                #expect(missing == [100])
                let full = #"{"common":{"oslist":"windows"},"extended":{"listofdlc":"200,400"},"depots":{"101":{"manifests":{"public":{"gid":"1"}}}}}"#
                return [SteamGenerationApp(id: 100, accessToken: String(UInt64.max), productInfo: full)]
            }
            #expect(ids == [200])
            #expect(missing.isEmpty)
            return [SteamGenerationApp(id: 200, accessToken: "22", productInfo: nil),
                    SteamGenerationApp(id: 400, accessToken: "44", productInfo: nil)]
        }
        model.addToLibrary(100, dlc: true, excludingDLC: [300, 400])
        await model.operation?.value
        let preview = try #require(model.pendingImport)
        #expect(preview.complete)
        let lua = try #require(preview.plan.documents.first)
        #expect(lua.tokens == [100: String(UInt64.max), 200: "22"])
        #expect(lua.dlcIDs == [200])
        #expect(Set(lua.depots.map(\.id)) == [101, 201])
    }
}
