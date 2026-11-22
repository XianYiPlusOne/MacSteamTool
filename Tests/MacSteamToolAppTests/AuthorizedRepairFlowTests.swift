import Foundation
import Testing
@testable import MacSteamTool
@testable import MacSteamToolCore

@Suite @MainActor struct AuthorizedRepairFlowTests {
    @Test func repairPreviewCommitAndDenial() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentRepair-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let model = AppModel(fixtureHome: root)
        model.preferences.autoMetadata = false
        let key = String(repeating: "ab", count: 32)
        model.libraryInfoFetch = { id in
            AppInfo(id: id, dictionary: ["common": ["oslist": "windows"], "depots": ["872415": ["manifests": ["public": ["gid": "123"]]]]])
        }
        let file = ImportFile(name: "872410.lua", data: Data("addappid(872410)".utf8))
        let service = LibraryService(paths: model.paths)
        var plan = try service.plan([file]); plan.warnings = ["Depot 872415 缺少密钥 / Missing depot key"]
        model.pendingImport = ImportSession(plan: plan, automatic: true, complete: false, includeDLC: false)
        func response(_ status: String) throws -> SteamEngineResponse {
            try JSONDecoder().decode(SteamEngineResponse.self, from: JSONSerialization.data(withJSONObject: ["ok": true, "appID": 872410, "depots": [["id": 872415, "owner": 872410, "sourceApp": 872410, "key": key, "result": status, "manifest": "123"]]]))
        }
        model.authorizedRepairFetch = { app, ids, dlc in
            #expect(app == 872410 && ids == [872415] && !dlc)
            return try response("AccessDenied")
        }
        model.repairAuthorizedContent(); await model.operation?.value
        #expect(model.message?.detail.contains("AccessDenied") == true)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.lua.appendingPathComponent("872410.lua").path))
        #expect(model.pendingImport?.complete == false)
        model.message = nil
        model.authorizedRepairFetch = { _, _, _ in try response("OK") }
        model.repairAuthorizedContent(); await model.operation?.value
        #expect(model.message == nil)
        #expect(model.pendingImport?.complete == true)
        #expect(!FileStore.fm.fileExists(atPath: model.paths.lua.appendingPathComponent("872410.lua").path))
        model.commitImport(); await model.operation?.value
        let config = try service.configSnapshot().0
        #expect(config.keys[872410]?[872415] == key)
        #expect(FileStore.fm.fileExists(atPath: model.paths.lua.appendingPathComponent("872410.lua").path))
    }
}
