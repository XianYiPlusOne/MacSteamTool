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
    @Test func incompleteAndUnavailableSourcesContinueToLaterFallbacks() async throws {
        var calls: [String] = []
        var log: [String] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false,
            appInfo: { _ in info(depots: [481, 482, 483]) }, cachedKeys: { [:] }, refreshKeys: { [:] },
            remote: { package([481]) }, remoteFallbacks: [
                ("Unavailable", { calls.append("Unavailable"); throw AppFailure("HTTP 404") }),
                ("Partial", { calls.append("Partial"); return package([482]) }),
                ("Complete", { calls.append("Complete"); return package([483]) }),
                ("Unused", { Issue.record("Unneeded fallback"); return [] })
            ], progress: { log.append($0) })
        #expect(result.complete)
        #expect(calls == ["Unavailable", "Partial", "Complete"])
        #expect(log.contains { $0.contains("Unavailable") && $0.contains("HTTP 404") })
        #expect(try Set(document(result).depots.map(\.id)) == [481, 482, 483])
    }
    @Test func completeRemoteDoesNotRequestGitHubFallback() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false,
            appInfo: { _ in info() }, cachedKeys: { [:] }, refreshKeys: { [:] },
            remote: { package([481]) }, remoteFallbacks: [("Unused", { Issue.record("Unneeded fallback"); return [] })])
        #expect(result.complete)
    }
    @Test func contentReportMapsNamedDLCToMissingDepot() async throws {
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true,
            appInfo: { id in
                var value = info(id, depots: id == 480 ? [481] : [491], dlc: id == 480 ? [490] : [])
                value.name = id == 480 ? "Main game" : "Soundtrack DLC — Full title"
                return value
            }, cachedKeys: { [481: key] }, refreshKeys: { [:] }, remote: { throw AppFailure("Offline") })
        #expect(!result.complete)
        let dlc = try #require(result.content.first { $0.id == 490 })
        #expect(dlc.name == "Soundtrack DLC — Full title"); #expect(!dlc.isMain)
        #expect(dlc.missingDepots == [491]); #expect(dlc.metadataKnown)
        #expect(result.content.first { $0.id == 480 }?.missingDepots.isEmpty == true)
    }
    @Test func completeCacheDoesNotRefreshOrDownload() async throws {
        var refreshes = 0, downloads = 0
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, appInfo: { _ in info() }, cachedKeys: { [481: key] }, refreshKeys: { refreshes += 1; return [:] }, remote: { downloads += 1; return [] })
        #expect(result.complete); #expect(result.warnings.isEmpty)
        #expect(refreshes == 0); #expect(downloads == 0)
        #expect(try document(result).depots.map(\.id) == [481])
    }
    @Test func steamLocalCacheCompletesImportBeforeNetwork() async throws {
        let home = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentSteamCache-\(UUID())")
        defer { try? FileStore.fm.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let vdf = """
        "InstallConfigStore" { "Software" { "Valve" { "Steam" { "depots" {
            "481" { "DecryptionKey" "\(String(repeating: "cd", count: 32))" }
            "482" { "DecryptionKey" "\(key.uppercased())" }
            "999" { "DecryptionKey" "\(key)" }
        } } } } }
        """
        try FileStore.write(Data(vdf.utf8), to: paths.steam.appendingPathComponent("config/config.vdf"))
        var stages: [String] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false,
            appInfo: { _ in info(depots: [481, 482]) }, cachedKeys: { [481: key] },
            steamCachedKeys: { missing in
                #expect(missing == [482])
                let local = try SteamLibrary.cachedDepotKeys(missing, paths: paths)
                #expect(local == [482: key])
                return local
            },
            refreshKeys: { Issue.record("Unexpected key refresh"); return [:] },
            remote: { Issue.record("Unexpected ZIP request"); return [] },
            remoteFallbacks: [
                ("Internet Archive", { Issue.record("Unexpected archive request"); return [] }),
                ("GitHub", { Issue.record("Unexpected GitHub request"); return [] })
            ], progress: { stages.append($0) })
        #expect(result.complete)
        let depots = try document(result).depots
        #expect(depots.map(\.id) == [481, 482])
        #expect(depots.allSatisfy { $0.key == key })
        #expect(stages.contains { $0.contains("Steam local depot cache") })
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
    @Test func archiveSourcesSupplyKeysWithoutPinningOldVersions() async throws {
        #expect(RemoteLuaPackage.libraryFallbacks(appID: 480).map(\.name) == [
            "Internet Archive · branches", "Internet Archive · NEW-depot-keys",
            "KeySteam · ManifestHubLua", "ManifestHub3", "ManifestHub · Steam-lua"
        ])
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false,
            appInfo: { _ in info(depots: [481, 482]) }, cachedKeys: { [481: key] }, refreshKeys: { [:] },
            remote: { throw AppFailure("ZIP offline") }, remoteFallbacks: [
                ("Archive fixture", {
                    try await RemoteLuaPackage.fetchArchiveKeys(appID: 480, collection: .branches) { url in
                        #expect(url.host == "archive.org")
                        #expect(url.path == "/download/manifest-hub-repo/branches.zip/branches/480/480.lua")
                        return package([482], extra: "setManifestid(482, \"42\", 0)\naddtoken(480, \"1234\")\n")[0].data
                    }
                })
            ])
        #expect(result.complete)
        let doc = try document(result)
        #expect(Set(doc.depots.map(\.id)) == [481, 482])
        #expect(doc.pins.isEmpty)
        #expect(doc.tokens.isEmpty)
    }
    @Test func archiveRejectsWrongAppAndKeylessResponse() async throws {
        for text in ["addappid(490)", "addappid(480)"] {
            await #expect(throws: (any Error).self) {
                try await RemoteLuaPackage.fetchArchiveKeys(appID: 480, collection: .depotKeys) { url in
                    #expect(url.path == "/download/manifest-hub-repo/NEW-depot-keys.zip/NEW-depot-keys/480/480.lua")
                    return Data(text.utf8)
                }
            }
        }
    }
    @Test func keySteamIndexResolvesOnlyMatchingLua() async throws {
        var paths: [String] = []
        let result = try await RemoteLuaPackage.fetchKeySteam(appID: 480) { url, _ in
            paths.append(url.path)
            if paths.count == 1 { return Data(#"{"f":["a1","b2"],"a":{"480":1}}"#.utf8) }
            return package([481])[0].data
        }
        #expect(paths == ["/trionine/ManifestHub/main/data/lua-map.json", "/bsinwhg/ManifestHubLua/main/luas/b2/480.lua"])
        #expect(result.first?.name == "480.lua")
        await #expect(throws: (any Error).self) {
            try await RemoteLuaPackage.fetchKeySteam(appID: 480) { url, _ in
                if url.path.hasSuffix(".json") { return Data(#"{"f":["a1"],"a":{"480":0}}"#.utf8) }
                return Data("addappid(490)".utf8)
            }
        }
        await #expect(throws: (any Error).self) {
            try await RemoteLuaPackage.fetchKeySteam(appID: 480) { url, _ in
                #expect(url.path.hasSuffix(".json"))
                return Data(#"{"f":["../other"],"a":{"480":0}}"#.utf8)
            }
        }
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
