import Foundation
import Testing
@testable import FluentCore

@Suite @MainActor struct LibraryContentScopeTests {
    let key = String(repeating: "ab", count: 32)
    func depot(_ os: String = "all", language: String = "", arch: String = "", manifests: [String: Any] = ["public": ["gid": "123"]]) -> [String: Any] {
        ["config": ["oslist": os, "language": language, "osarch": arch], "manifests": manifests]
    }
    func info(_ id: Int = 480, os: String = "windows", depots: [String: Any], dlc: [Int] = []) -> AppInfo {
        var data = depots
        data["branches"] = ["public": ["buildid": "1"], "beta": ["buildid": "2"]]
        return AppInfo(id: id, dictionary: ["common": ["name": "Fixture", "oslist": os], "depots": data, "extended": ["listofdlc": dlc]])
    }
    func resolve(_ info: AppInfo, keys: [Int: String], context: LibraryInstallContext = .init()) async throws -> AutomaticLibraryResult {
        try await AutomaticLibraryImport.resolve(appID: info.id, includeDLC: true, context: context, appInfo: { _ in info }, cachedKeys: { keys }, refreshKeys: { keys }, remote: { [ImportFile(name: "\(info.id).lua", data: Data("addappid(\(info.id))".utf8))] })
    }
    func ids(_ result: AutomaticLibraryResult) throws -> Set<Int> {
        Set(try LuaDocument.parse(String(decoding: result.files[0].data, as: UTF8.self)).depots.map(\.id))
    }
    @Test func optionalDLCWithMissingMetadataOrKeysIsOmittedFromPreview() async throws {
        let id = 2852190
        let available = 3581270
        let missing = [3932360, 4283830, 3879370, 3879420]
        let main = info(id, depots: ["2852191": depot()], dlc: missing + [available])
        let result = try await AutomaticLibraryImport.resolve(appID: id, includeDLC: true,
            skipUnavailableDLC: true, appInfo: { child in
                if child == id { return main }
                if child == missing.first { throw AppFailure("Metadata unavailable") }
                return info(child, depots: [String(child): depot()])
            }, cachedKeys: { [2852191: key, available: key] }, refreshKeys: { [:] },
            remote: { throw AppFailure("Remote package unavailable") },
            remoteFallbacks: [("Last fallback", { throw AppFailure("Optional content unavailable") })])
        #expect(result.complete)
        #expect(result.skippedDLC == Set(missing))
        #expect(try ids(result) == [2852191, available])
        #expect(try LuaDocument.parse(String(decoding: result.files[0].data, as: UTF8.self)).dlcIDs == [available])
    }

    @Test func triesLastFallbackBeforeDroppingOptionalDLC() async throws {
        let main = info(depots: ["481": depot()], dlc: [490])
        let dlc = info(490, depots: ["491": depot(), "492": depot()])
        var attempts: [String] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true,
            skipUnavailableDLC: true, appInfo: { $0 == 480 ? main : dlc },
            cachedKeys: { [481: key] }, refreshKeys: { [:] },
            remote: {
                attempts.append("ZIP")
                let lua = "addappid(480)\naddappid(491, 1, \"\(key)\")"
                return [ImportFile(name: "480.lua", data: Data(lua.utf8))]
            }, remoteFallbacks: [("Last fallback", {
                attempts.append("Last fallback")
                let lua = "addappid(480)\naddappid(492, 1, \"\(key)\")"
                return [ImportFile(name: "480.lua", data: Data(lua.utf8))]
            })])
        #expect(attempts == ["ZIP", "Last fallback"])
        #expect(result.complete)
        #expect(result.skippedDLC.isEmpty)
        #expect(try ids(result) == [481, 491, 492])
        #expect(try LuaDocument.parse(String(decoding: result.files[0].data, as: UTF8.self)).dlcIDs == [490])
    }

    @Test func explicitlyExcludedOptionalDLCIsNotQueriedOrWritten() async throws {
        var childDepot = depot(); childDepot["dlcappid"] = 490
        let main = info(depots: ["481": depot(), "491": childDepot], dlc: [490])
        var queries: [Int] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, excludingDLC: [490], appInfo: { id in
            queries.append(id); return main
        }, cachedKeys: { [481: key] }, refreshKeys: { Issue.record("Excluded DLC must not require keys"); return [:] }, remote: { [] })
        #expect(result.complete)
        #expect(queries == [480])
        #expect(try ids(result) == [481])
        #expect(try LuaDocument.parse(String(decoding: result.files[0].data, as: UTF8.self)).dlcIDs.isEmpty)
        #expect(result.notes.contains { $0.contains("490") })
    }
    @Test func exclusionCannotSuppressBaseOrSharedDepotRequirements() async throws {
        let main = info(depots: ["481": depot(), "482": depot()], dlc: [490])
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: true, excludingDLC: [480, 482, 490], appInfo: { _ in main }, cachedKeys: { [481: key] }, refreshKeys: { [:] }, remote: { [ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))] })
        #expect(!result.complete)
        #expect(result.warnings.contains { $0.contains("482") })
        #expect(try ids(result) == [481])
    }

    @Test func hadesMacDoesNotRequireMissingWindowsDepot() async throws {
        let game = info(1145360, os: "windows,macos", depots: ["1145361": depot("windows"), "1145362": depot("windows"), "1145363": depot("windows"), "1145364": depot("macos", arch: "64")])
        var downloads = 0
        let result = try await AutomaticLibraryImport.resolve(appID: game.id, includeDLC: true, appInfo: { _ in game }, cachedKeys: { [1145361: key, 1145363: key, 1145364: key] }, refreshKeys: { Issue.record("Native content is already complete"); return [:] }, remote: { downloads += 1; return [] })
        #expect(result.complete); #expect(downloads == 0)
        #expect(try ids(result) == [1145364]); #expect(result.notes.contains { $0.contains("macos") })
        let windows = try await resolve(game, keys: [1145361: key, 1145363: key, 1145364: key], context: .init(platform: .windows))
        #expect(!windows.complete); #expect(windows.warnings.contains { $0.contains("1145362") })
        #expect(try ids(windows) == [1145361, 1145363])
    }

    @Test func contentCheckerReportsMissingKeysForSelectedPlatform() async throws {
        let game = info(4618570, os: "windows,macos", depots: [
            "4618572": depot("all"),
            "4618573": depot("macos"),
            "4618571": depot("windows")
        ])
        let context = LibraryInstallContext(platform: .macos)
        let complete = try await LibraryContentChecker.check(
            appID: game.id, includeDLC: false, context: context,
            keys: [4618572: key, 4618573: key],
            appInfo: { _ in game }
        )
        #expect(complete.complete)

        let missing = try await LibraryContentChecker.check(
            appID: game.id, includeDLC: false, context: context,
            keys: [4618572: key],
            appInfo: { _ in game }
        )
        #expect(missing.missingDepotIDs == [4618573])
        #expect(!missing.complete)
    }
    @Test func unpublishedMacPlaceholderDoesNotDisplaceWindowsBuild() async throws {
        let game = info(os: "windows,macos", depots: ["481": depot("windows"), "482": depot("macos", manifests: [:]), "483": depot(manifests: [:])])
        let result = try await resolve(game, keys: [481: key])
        #expect(result.complete); #expect(try ids(result) == [481])
        #expect(result.notes.contains { $0.contains("windows") })
        #expect(result.notes.contains { $0.contains("483") })
    }
    @Test func selectedBranchLanguageAndArchitectureDefineRequiredContent() async throws {
        let game = info(depots: ["481": depot(manifests: ["beta": ["gid": "567"]]), "482": depot(language: "english"), "483": depot(language: "schinese", manifests: ["beta": ["gid": "568"]]), "484": depot(arch: "32", manifests: ["beta": ["gid": "569"]]), "485": depot()])
        let result = try await resolve(game, keys: [481: key, 483: key], context: .init(platform: .windows, branch: "beta", language: "schinese"))
        #expect(result.complete); #expect(try ids(result) == [481, 483])
    }
    @Test func missingLanguageOrMalformedManifestCannotPass() async throws {
        let language = try await resolve(info(depots: ["481": depot(), "482": depot(language: "japanese")]), keys: [481: key, 482: key])
        #expect(!language.complete); #expect(language.warnings.contains { $0.contains("语言") })
        let manifest = try await resolve(info(depots: ["481": depot(), "482": depot(manifests: ["public": ["gid": "invalid"]])]), keys: [481: key, 482: key])
        #expect(!manifest.complete); #expect(manifest.warnings.contains { $0.contains("清单无效") })
    }
    @Test func forcingWindowsCannotTreatMacOnlyCommonFilesAsWindowsBuild() async throws {
        let result = try await resolve(info(os: "macos", depots: ["481": depot()]), keys: [481: key], context: .init(platform: .windows))
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("运行平台") })
    }
    @Test func absentBranchEvidenceIsNotAssumedToBePlaceholder() async throws {
        let game = AppInfo(id: 480, dictionary: ["common": ["oslist": "windows"], "depots": ["481": depot(), "482": depot(manifests: [:])]])
        let result = try await resolve(game, keys: [481: key])
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("482") && $0.contains("无法核实") })
    }
    @Test func encryptedSelectedBranchIsNotSilentlySkipped() async throws {
        let game = info(depots: ["481": depot(manifests: ["beta": ["gid": "567"]]), "482": ["encryptedmanifests": ["beta": ["encrypted_gid": "ciphertext"]]]])
        let result = try await resolve(game, keys: [481: key, 482: key], context: .init(platform: .windows, branch: "beta"))
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("受限") })
    }
    @Test func sharedDepotsResolveSourceAndInheritRestrictions() async throws {
        let game = info(depots: ["481": depot("windows"), "482": ["depotfromapp": "460"], "483": ["depotfromapp": "460"]])
        let source = info(460, os: "windows,linux", depots: ["482": depot("windows"), "483": depot("linux")])
        var queries: [Int] = []
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { id in queries.append(id); return id == 480 ? game : source }, cachedKeys: { [481: key, 482: key] }, refreshKeys: { Issue.record("Resolved shared content is complete"); return [:] }, remote: { [] })
        #expect(result.complete); #expect(queries == [480, 460]); #expect(try ids(result) == [481, 482])
        #expect(AutomaticCompatibility.assess(info: game, available: [481, 482]) == .windowsOnly)
    }
    @Test func missingSharedSourceCannotBeCalledCompleteEvenWithKey() async throws {
        let game = info(depots: ["481": depot(), "482": ["depotfromapp": "460"]])
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { id in if id == 460 { throw AppFailure("Offline") }; return game }, cachedKeys: { [481: key, 482: key] }, refreshKeys: { [:] }, remote: { [ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))] })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("482") && $0.contains("无法核实") })
    }
    @Test func sharedSourceCycleDoesNotLoopOrPass() async throws {
        let game = info(depots: ["481": depot(), "482": ["depotfromapp": "460"]])
        let source = info(460, depots: ["482": ["depotfromapp": "480"]])
        let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: false, appInfo: { $0 == 480 ? game : source }, cachedKeys: { [481: key, 482: key] }, refreshKeys: { [:] }, remote: { [ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))] })
        #expect(!result.complete); #expect(result.warnings.contains { $0.contains("循环") })
    }
    @Test func unselectedDLCCannotBlockBaseButSelectedDLCStillCan() async throws {
        let main = info(depots: ["481": depot()], dlc: [490])
        let child = info(490, depots: ["491": depot()])
        for include in [false, true] {
            let result = try await AutomaticLibraryImport.resolve(appID: 480, includeDLC: include, appInfo: { $0 == 480 ? main : child }, cachedKeys: { [481: key] }, refreshKeys: { [:] }, remote: { [ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))] })
            #expect(result.complete == !include)
            #expect(result.warnings.contains { $0.contains("491") } == include)
        }
    }
    @Test func perGameRuntimeAndInstalledPreferencesAreRespected() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let config = Data("\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"language\" \"english\" \"CompatToolMapping\" { \"0\" { \"name\" \"notproton-1.2.3\" } } } } } }".utf8)
        let file = paths.steam.appendingPathComponent("config/config.vdf")
        try FileStore.write(config, to: file)
        #expect(try LibraryInstallContext.read(appID: 480, paths: paths).platform == .automatic)
        try FileStore.write(SteamCompatibility.edit(config, appID: 480, tool: "notproton-1.2.3"), to: file)
        let acf = paths.steam.appendingPathComponent("steamapps/appmanifest_480.acf")
        try FileStore.write(Data("\"AppState\" { \"appid\" \"480\" \"UserConfig\" { \"language\" \"schinese\" \"BetaKey\" \"beta\" } }".utf8), to: acf)
        let context = try LibraryInstallContext.read(appID: 480, paths: paths)
        #expect(context.platform == .windows); #expect(context.language == "schinese"); #expect(context.branch == "beta")
    }
    @Test func steamRegistryLanguageIsUsedWithoutAppUILanguage() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root)
        try FileStore.write(Data("\"Registry\" { \"HKCU\" { \"Software\" { \"Valve\" { \"Steam\" { \"language\" \"japanese\" } } } } }".utf8), to: paths.steam.appendingPathComponent("registry.vdf"))
        #expect(try LibraryInstallContext.read(appID: 480, paths: paths).language == "japanese")
    }
}
