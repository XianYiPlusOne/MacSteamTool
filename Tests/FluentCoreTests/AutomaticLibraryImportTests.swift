import Foundation
import Testing
@testable import FluentCore

@Suite @MainActor struct AutomaticLibraryImportTests {
    let key = String(repeating: "ab", count: 32)
    func info(_ id: Int = 480, depots: [Int] = [481], dlc: [Int] = []) -> AppInfo {
        var data: [String: Any] = ["branches": ["public": ["buildid": "1"]]]
        for depot in depots { data[String(depot)] = ["config": ["oslist": "windows"], "manifests": ["public": ["gid": "123"]]] }
        return AppInfo(id: id, dictionary: ["common": ["name": "Fixture \(id)", "oslist": "windows"], "extended": ["listofdlc": dlc], "depots": data])
    }
    func package(_ depots: [Int], extra: String = "") -> [ImportFile] {
        [ImportFile(name: "480.lua", data: Data(("addappid(480)\n" + depots.map { "addappid(\($0), 1, \"\(key)\")\n" }.joined() + extra).utf8))]
    }
    func document(_ result: AutomaticLibraryResult) throws -> LuaDocument {
        try LuaDocument.parse(String(decoding: result.files[0].data, as: UTF8.self))
    }
    @Test func completeCacheDoesNotRefreshOrDownload() async throws {
        var refreshes = 0, downloads = 0
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { _ in info() }, cachedKeys: { [481: key] }, refreshKeys: { refreshes += 1; return [:] }, remote: { downloads += 1; return [] })
        #expect(result.complete); #expect(result.warnings.isEmpty)
        #expect(refreshes == 0); #expect(downloads == 0)
        #expect(try document(result).depots.map(\.id) == [481])
    }
    @Test func refreshOnceFillsGapsAndRetainsPreviouslyCachedKeys() async throws {
        var refreshes = 0, downloads = 0
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { _ in info(depots: [481, 482]) }, cachedKeys: { [481: key] }, refreshKeys: { refreshes += 1; return [482: key] }, remote: { downloads += 1; return [] })
        #expect(result.complete); #expect(refreshes == 1); #expect(downloads == 0)
        #expect(try Set(document(result).depots.map(\.id)) == [481, 482])
    }
    @Test func localFailuresAutomaticallyUseRemote() async throws {
        var refreshes = 0, downloads = 0
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { _ in info() }, cachedKeys: { throw AppFailure("Cache corrupt") }, refreshKeys: { refreshes += 1; throw AppFailure("Offline") }, remote: { downloads += 1; return package([481]) })
        #expect(result.complete); #expect(result.warnings.isEmpty)
        #expect(refreshes == 1); #expect(downloads == 1)
    }
    @Test func partialDLCKeysAreCompletedAcrossSources() async throws {
        var queried: [Int] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { id in
            queried.append(id)
            return id == 480 ? info(dlc: [490]) : info(490, depots: [491, 492], dlc: [480])
        }, cachedKeys: { [481: key, 491: key] }, refreshKeys: { [:] }, remote: { package([], extra: "addappid(490)\naddappid(492, 1, \"\(key)\")\n") })
        #expect(result.complete); #expect(queried == [480, 490])
        let doc = try document(result)
        #expect(doc.dlcIDs == [490]); #expect(doc.depots.first { $0.id == 492 }?.owner == 490)
        #expect(Set(doc.depots.map(\.id)) == [481, 491, 492])
    }
    @Test func remoteMissingDLCKeysIsNotComplete() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { id in id == 480 ? info(dlc: [490]) : info(490, depots: [491, 492]) }, cachedKeys: { [481: key] }, refreshKeys: { [:] }, remote: { package([481], extra: "addappid(490)\naddappid(491, 1, \"\(key)\")\n") })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("492") })
    }
    @Test func excludeDLCAlsoScopesRemotePackage() async throws {
        var queried: [Int] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { id in queried.append(id); return info(dlc: [490]) }, cachedKeys: { [:] }, refreshKeys: { [:] }, remote: { package([481], extra: "addappid(490)\naddappid(491, 1, \"\(key)\")\n") })
        #expect(result.complete); #expect(queried == [480])
        let doc = try document(result)
        #expect(doc.dlcIDs.isEmpty); #expect(doc.depots.map(\.id) == [481])
    }
    @Test func unknownDLCMetadataCannotBeDeclaredComplete() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { id in if id == 490 { throw AppFailure("Metadata unavailable") }; return info(dlc: [490]) }, cachedKeys: { [481: key] }, refreshKeys: { [:] }, remote: { package([481], extra: "addappid(490)\naddappid(491, 1, \"\(key)\")\n") })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("DLC 490") })
        #expect(try document(result).depots.contains { $0.id == 491 })
    }
    @Test func missingMainMetadataOnlyAllowsPreview() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in throw AppFailure("Metadata offline") }, cachedKeys: { Issue.record("Should not read keys"); return [:] }, refreshKeys: { Issue.record("Should not refresh keys"); return [:] }, remote: { package([481], extra: "addappid(490)\naddappid(491, 1, \"\(key)\")\n") })
        #expect(!result.complete); #expect(!result.warnings.isEmpty)
        #expect(try document(result).dlcIDs.isEmpty)
    }
    @Test func sharedDepotIsRequiredEvenThoughLegacyGeneratorOmitsIt() async throws {
        let shared = AppInfo(id: 480, dictionary: ["common": ["oslist": "windows"], "depots": ["481": ["depotfromapp": "460"]]])
        #expect(shared.depots.isEmpty); #expect(shared.sharedDepots?.map(\.id) == [481])
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in shared }, cachedKeys: { [:] }, refreshKeys: { [:] }, remote: { package([]) })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("481") })
    }
    @Test func emptyMainDepotMetadataDoesNotMeanComplete() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in info(depots: []) }, cachedKeys: { [:] }, refreshKeys: { [:] }, remote: { package([481]) })
        #expect(!result.complete); #expect(!result.warnings.isEmpty)
        #expect(try document(result).depots.map(\.id) == [481])
    }
    @Test func conflictingRemoteKeysRetainLocalCandidateForReview() async throws {
        let other = String(repeating: "cd", count: 32)
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in info(depots: [481, 482]) }, cachedKeys: { [481: key] }, refreshKeys: { [:] }, remote: { package([482], extra: "addappid(481, 1, \"\(other)\")\n") })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("冲突") })
        #expect(try document(result).depots.first?.key == key)
        #expect(try document(result).depots.count == 1)
    }
    @Test func wrongGameAndTotalFailureNeverProduceSuccessfulResult() async throws {
        await #expect(throws: (any Error).self) {
            try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in info() }, cachedKeys: { [:] }, refreshKeys: { [:] }, remote: { [ImportFile(name: "490.lua", data: Data("addappid(490)".utf8))] })
        }
        await #expect(throws: (any Error).self) {
            try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in info() }, cachedKeys: { [:] }, refreshKeys: { throw AppFailure("Offline") }, remote: { throw AppFailure("Unavailable") })
        }
    }
    @Test func cancellationNeverStartsFallback() async throws {
        var downloads = 0
        await #expect(throws: CancellationError.self) {
            try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in info() }, cachedKeys: { [:] }, refreshKeys: { throw CancellationError() }, remote: { downloads += 1; return package([481]) })
        }
        #expect(downloads == 0)
    }
    @Test func unsupportedRemoteStatementsRequireReview() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { _ in info() }, cachedKeys: { [:] }, refreshKeys: { [:] }, remote: { package([481], extra: "unsupported(480)\n") })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("Unconverted") })
    }
    @Test func oldSourcePreferenceDoesNotControlAutomaticImport() throws {
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        record["librarySource"] = "remote"; record["remotePackageMode"] = "direct"
        let preferences = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: record))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        #expect(saved["librarySource"] == nil); #expect(preferences.remotePackageMode == "direct")
    }
}
