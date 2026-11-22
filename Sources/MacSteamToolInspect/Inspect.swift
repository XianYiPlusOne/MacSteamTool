import Foundation
import MacSteamToolCore

/// Read-only diagnostics. Fixture creation is explicit and never targets the real home.
@main struct Inspect {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--verify-game-cover", args.count >= 3, let app = TextUtil.validID(args[1]) {
            let root = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
            guard root.path != FileStore.fm.homeDirectoryForCurrentUser.path, FileStore.fm.fileExists(atPath: root.appendingPathComponent(".fluent-cover-fixture").path) else { throw AppFailure("Explicit isolated cover cache required") }
            let reference = args.count == 4 ? args[3] : nil
            let data = try await GameCovers(cache: root.appendingPathComponent("Covers"), fetch: { url in
                let start = Date()
                do {
                    let data = try await GameCovers.fetchImage(url)
                    print("IMAGE \(url.host ?? "") \(data.count) bytes \(Int(Date().timeIntervalSince(start)*1000)) ms valid=\(GameCovers.validImage(data))")
                    return data
                } catch {
                    let value = error as NSError
                    print("IMAGE FAILED \(url.host ?? "") \(value.domain) \(value.code): \(value.localizedDescription)")
                    throw error
                }
            }).load(appID: app, reference: reference)
            guard GameCovers.validImage(data) else { throw AppFailure("Cover did not decode") }
            print("PASS: cover \(app), \(data.count) bytes, decoded and persisted in isolated cache"); return
        }
        if args.first == "--exercise-patch-platform", args.count == 4 {
            let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().standardizedFileURL
            guard root.path != FileStore.fm.homeDirectoryForCurrentUser.path, FileStore.fm.fileExists(atPath: root.appendingPathComponent(".fluent-patch-fixture").path) else { throw AppFailure("Explicit isolated patch fixture required") }
            let paths = AppPaths(home: root), game = root.appendingPathComponent("Game"), exe = game.appendingPathComponent("FixtureGame.exe")
            let metadata = try JSONSerialization.jsonObject(with: FileStore.read(root.appendingPathComponent("runtime.json"))) as? [String: String] ?? [:]
            let direct = metadata["kind"] == "crossOver", bottle = root.appendingPathComponent("Library/Application Support/Steam/steamapps/compatdata/900001/pfx")
            guard bottle.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw AppFailure("Fixture bottle must be isolated") }
            if ["preview", "deploy"].contains(args[2]) {
                var plan = try GamePatches.windowsPlan(package: root.appendingPathComponent("Payload"), gameRoot: game, appID: 900001, executable: exe, paths: paths, bottle: direct ? bottle : nil, crossOverApp: direct ? root.appendingPathComponent("CrossOver.app") : nil)
                plan = try GamePatches.addingOverrides(to: plan, executable: exe, libraries: ["version"], paths: paths)
                if args[2] == "deploy" { try await PatchLoadVerification.assertStopped(target: plan.windowsTarget!, appID: plan.appID, paths: paths); try FileStore.json(GamePatches.install(plan, paths: paths), to: root.appendingPathComponent("receipt.json")) }
                print("PASS: Windows \(plan.windowsTarget!.architecture.rawValue) / \(plan.windowsTarget!.kind.rawValue) platform and architecture validated; \(args[2])"); return
            }
            let receipt = try FileStore.decode(PatchReceipt.self, at: root.appendingPathComponent("receipt.json"))
            guard receipt.appID == 900001, receipt.gameRoot == game.path, receipt.windowsTarget?.executable == exe.path,
                  receipt.windowsTarget?.prefix == bottle.resolvingSymlinksInPath().path else { throw AppFailure("Fixture receipt escaped scope") }
            if args[2] == "stopped" {
                try await PatchLoadVerification.assertStopped(target: receipt.windowsTarget!, appID: receipt.appID, paths: paths); print("PASS: selected Windows bottle stopped"); return
            }
            if args[2] == "check" {
                let result = try await PatchLoadVerification.check(receipt, paths: paths, helper: URL(fileURLWithPath: args[3]))
                print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)); return
            }
            if args[2] == "restore" { try await PatchLoadVerification.assertStopped(target: receipt.windowsTarget!, appID: receipt.appID, paths: paths); try GamePatches.restore(receipt, paths: paths); print("PASS: fixture patch and registry restored"); return }
            throw AppFailure("Unknown isolated patch action")
        }
        if args.first == "--exercise-retired-cleanup", args.count == 3 {
            let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath().standardizedFileURL
            let prefix = "dev.fluentsteam.fixture-removal.", label = args[2]
            guard root.path != FileStore.fm.homeDirectoryForCurrentUser.path,
                  FileStore.fm.fileExists(atPath: root.appendingPathComponent(".fluent-retirement-fixture").path),
                  label.hasPrefix(prefix), UUID(uuidString: String(label.dropFirst(prefix.count))) != nil else { throw AppFailure("Explicit isolated retirement fixture and unique test service required") }
            try RetiredFeatureCleanup.run(home: root, paths: AppPaths(home: root)) { arguments in
                guard arguments.count == 2, ["print", "bootout"].contains(arguments[0]), arguments[1].hasSuffix("/dev.fluentsteam.mac.trainer-agent") else { throw AppFailure("Unexpected cleanup scope") }
                let domain = arguments[1].split(separator: "/").dropLast().joined(separator: "/")
                return try RetiredFeatureCleanup.runLaunchctl([arguments[0], domain + "/" + label])
            }
            print("PASS: isolated upgrade cleanup; only the unique fixture launchd service was targeted"); return
        }
        if args.first == "--verify-remote-package", args.count >= 3, let id = TextUtil.validID(args[1]) {
            var preferences = Preferences()
            if args.count == 4 { preferences.remotePackageMode = "direct"; preferences.remotePackageURL = args[3] }
            let files = try await RemoteLuaPackage.fetch(appID: id, preferences: preferences, engine: URL(fileURLWithPath: args[2]))
            let home = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentRemoteFlow-\(UUID().uuidString)")
            defer { try? FileStore.fm.removeItem(at: home) }
            let service = LibraryService(paths: AppPaths(home: home))
            let plan = try service.plan(files); try service.perform(plan)
            guard try SteamLibrary.games(service.paths).contains(where: { $0.id == id && $0.enabled }) else { throw AppFailure("Remote import did not reach the fixture library") }
            print("PASS: remote HTTP -> ZIP -> AppID validation -> plan -> isolated import; \(files.count) Lua files, AppID \(id)"); return
        }
        if args.first == "--verify-chart-pagination", args.count == 2 {
            let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
            guard root.path != FileStore.fm.homeDirectoryForCurrentUser.path, FileStore.fm.fileExists(atPath: root.appendingPathComponent(".fluent-chart-fixture").path) else { throw AppFailure("Explicit isolated chart cache required") }
            let store = DiscoveryChartStore(file: root.appendingPathComponent("Charts/popular.json"))
            let first = try await store.refresh()
            let next = try await store.loadMore()
            guard next.games.count > first.games.count, Set(next.games.map(\.id)).count == next.games.count,
                  Array(next.games.prefix(first.games.count).map(\.id)) == first.games.map(\.id),
                  (next.nextOffset ?? 0) > (first.nextOffset ?? 0) else { throw AppFailure("Pagination did not append distinct games") }
            print("PASS: production pagination \(first.games.count) -> \(next.games.count) games; offset \(first.nextOffset ?? 0) -> \(next.nextOffset ?? 0); old order preserved, unique and cached")
            return
        }
        if args.first == "--verify-public-charts", args.count <= 2 {
            let start = Date()
            let games: [GameMetadata]
            if args.count == 2 {
                let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
                guard root.path != FileStore.fm.homeDirectoryForCurrentUser.path, FileStore.fm.fileExists(atPath: root.appendingPathComponent(".fluent-chart-fixture").path) else { throw AppFailure("Explicit isolated chart cache required") }
                games = try await DiscoveryChartStore(file: root.appendingPathComponent("Charts/popular.json")).refresh().games
            } else { games = try await DiscoveryCharts.load() }
            guard !games.isEmpty else { throw AppFailure("Public chart empty") }
            print("PASS: production single-page chart/cache: \(games.count) games, \(Int(Date().timeIntervalSince(start)*1000)) ms"); return
        }
        if args.first == "--game-startup", args.count == 2, let id = TextUtil.validID(args[1]) {
            guard let game = SteamLibrary.installed(AppPaths()).first(where: { $0.id == id }) else { throw AppFailure("Installed game not found") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(GameStartupDiagnostics.inspect(game)), as: UTF8.self)); return
        }
        if ["--verify-library-import", "--exercise-library-import"].contains(args.first ?? ""), args.count >= 3 {
            let files = try await ArchiveIO.importFiles(args.dropFirst(2).map { URL(fileURLWithPath: $0) }, engine: URL(fileURLWithPath: args[1]))
            if args.first == "--exercise-library-import" {
                let home = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentImportFixture-\(UUID().uuidString)")
                defer { try? FileStore.fm.removeItem(at: home) }
                let paths = AppPaths(home: home), service = LibraryService(paths: AppPaths(home: home))
                let baseline = Data("HideWhatsNew: no\n".utf8); try FileStore.write(baseline, to: paths.config)
                let plan = try service.plan(files); try service.perform(plan)
                for file in files {
                    let destination = file.name.hasSuffix(".lua") ? paths.lua.appendingPathComponent(file.name) : file.name.hasSuffix(".manifest") ? paths.depotCache.appendingPathComponent(file.name) : paths.steam.appendingPathComponent("appcache/stats/\(file.name)")
                    guard try FileStore.read(destination) == file.data else { throw AppFailure("Import transaction content mismatch") }
                }
                let journal = FileTransaction(backupRoot: paths.backups)
                guard let backup = journal.records().first else { throw AppFailure("Import backup missing") }
                try journal.restore(backup, allowedRoots: [paths.macSteam, paths.lua, paths.steam, AutomaticCompatibility.file(paths), AutomaticAchievements.file(paths)])
                guard try FileStore.read(paths.config) == baseline, try SteamLibrary.games(paths).isEmpty else { throw AppFailure("Import rollback mismatch") }
            }
            let report = files.map { ["name": $0.name, "sha256": FileStore.hash($0.data)] }
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)); return
        }
        if args.first == "--prepare-official-runtime", args.count == 4 {
            let engine = URL(fileURLWithPath: args[2]), cache = URL(fileURLWithPath: args[3])
            let release = try await OfficialRuntimeUpdates.check(args[1], engine: engine)
            let prepared = try await OfficialRuntimeUpdates.prepare(release, engine: engine, cache: cache)
            let report: [String: Any] = ["ok": true, "provider": release.provider, "version": release.version, "sha256": release.sha256, "source": release.url, "application": prepared.application.path, "steamBuilds": prepared.supportedSteamBuilds]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)); return
        }
        if args.first == "--prepare-achievements", args.count == 3, let id = TextUtil.validID(args[1]) {
            try await AchievementRepair.prepare(appID: id, paths: AppPaths(), worker: URL(fileURLWithPath: args[2]))
            print("Achievement schema prepared; only selected app enabled. Restart Steam to apply.")
            return
        }
        if args.first == "--repair-workshop-key", args.count == 2, let id = TextUtil.validID(args[1]) {
            let record = try WorkshopKeys.repair(appID: id, paths: AppPaths())
            print(record.map { "Repaired Workshop key for AppID \(id); backup \($0.id). Restart Steam and retry the download to verify." } ?? "Workshop key already present; no changes.")
            return
        }
        if args.first == "--compatibility", args.count == 3, let appID = TextUtil.validID(args[1]) {
            let backup = try SteamCompatibility.save(paths: AppPaths(), appID: appID, tool: args[2] == "automatic" ? nil : args[2])
            print("PASS: backed up and saved compatibility mapping for AppID \(appID); backup \(backup.id)"); return
        }
        if args.first == "--exercise-update", args.count == 5 {
            // Full-bundle regression in an explicitly new test directory. The
            // installed application and its data are never used as the target.
            let root = URL(fileURLWithPath: args[4]).standardizedFileURL.resolvingSymlinksInPath()
            guard root.path.hasPrefix("/"), !FileStore.fm.fileExists(atPath: root.path) else { throw AppFailure("Update fixture requires a new directory") }
            guard let key = Data(base64Encoded: try FileStore.text(URL(fileURLWithPath: args[3])).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AppFailure("Invalid public key") }
            let envelope = try FileStore.decode(SignedUpdate.self, at: URL(fileURLWithPath: args[1]))
            let prepared = try await AppUpdates.prepare(envelope, publicKey: key, archive: URL(fileURLWithPath: args[2]), staging: root.appendingPathComponent("stage"), currentBuild: 0)
            let target = root.appendingPathComponent("MacSteamTool.app")
            try FileStore.fm.copyItem(at: prepared.application, to: target)
            let info = target.appendingPathComponent("Contents/Info.plist")
            var plist = try PropertyListSerialization.propertyList(from: FileStore.read(info), format: nil) as! [String: Any]
            plist["CFBundleVersion"] = "1"; plist["CFBundleShortVersionString"] = "0.1.0"
            try FileStore.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: info)
            let (sign, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--deep", "--sign", "-", target.path])
            guard sign == 0 else { throw AppFailure("Fixture signing failed") }
            let before = try AppUpdates.treeHash(target), after = try AppUpdates.treeHash(prepared.application)
            let plan = UpdateInstallPlan(source: prepared.application, target: target, expectedSource: after, expectedTarget: before, parentPID: 0, build: prepared.release.build)
            let planURL = root.appendingPathComponent("install.json"), helper = root.appendingPathComponent("MacSteamToolUpdater")
            try FileStore.json(plan, to: planURL)
            try FileStore.fm.copyItem(at: prepared.application.appendingPathComponent("Contents/MacOS/MacSteamToolUpdater"), to: helper)
            let (code, diagnostic) = try await ProcessRunner.run(helper, [planURL.path])
            let result = try FileStore.decode([String: String].self, at: root.appendingPathComponent("install-result.json"))
            guard code == 0, result["ok"] == "true", let backup = result["backup"], try AppUpdates.treeHash(target) == after, try AppUpdates.treeHash(URL(fileURLWithPath: backup)) == before else { throw AppFailure("Full update helper failed: " + diagnostic) }
            print("PASS: real signed release extracted, full previous bundle upgraded by the shipped helper, replacement and backup hashes verified; launch requested for private test application."); return
        }
        if args.first == "--mirrors" {
            for value in await DownloadSources.measureMirrors() {
                print("\(value.error == nil ? "PASS" : "UNAVAILABLE"): \(value.id) · \(value.milliseconds) ms · \(value.bytes) bytes\(value.error.map { " · " + $0 } ?? "")")
            }
            return
        }
        if args.first == "--verify-update", args.count == 4 {
            let feed = URL(fileURLWithPath: args[1]), archive = URL(fileURLWithPath: args[2])
            guard let key = Data(base64Encoded: try FileStore.text(URL(fileURLWithPath: args[3])).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AppFailure("Invalid public key") }
            let envelope = try FileStore.decode(SignedUpdate.self, at: feed)
            let staging = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentUpdateVerify-\(UUID().uuidString)")
            defer { try? FileStore.fm.removeItem(at: staging) }
            let result = try await AppUpdates.prepare(envelope, publicKey: key, archive: archive, staging: staging, currentBuild: 0)
            print("PASS: signed release \(result.release.version) build \(result.release.build); ZIP digest, extraction, bundle identity, ARM64 and strict code signatures verified."); return
        }
        if args.first == "--wine-plan", args.count == 4, let appID = TextUtil.validID(args[2]) {
            var paths = AppPaths(); paths.steam = URL(fileURLWithPath: args[1])
            let launch = try WineLaunch.prepare(appID: appID, command: args[3], paths: paths)
            let keys: Set<String> = ["WINEPREFIX", "CX_ROOT", "CX_HOME", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEDLLOVERRIDES", "STEAM_COMPAT_CLIENT_INSTALL_PATH", "SteamAppId", "SteamGameId", "WINEMSYNC", "PATH"]
            let report: [String: Any] = ["executable": launch.executable.path, "arguments": launch.arguments, "environment": launch.environment.filter { keys.contains($0.key) }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)); return
        }
        if args.first == "--wine-override-preview", args.count == 4 {
            let bytes = try WineOverrides.edit(FileStore.read(URL(fileURLWithPath: args[1])), executable: args[2], libraries: args[3].split(separator: ",").map(String.init))
            print(bytes.base64EncodedString()); return
        }
        if args.first == "--fixture", args.count == 2 {
            let home = URL(fileURLWithPath: args[1]).standardizedFileURL
            guard home.path.hasPrefix("/"), home != FileManager.default.homeDirectoryForCurrentUser, !FileStore.fm.fileExists(atPath: home.path) else { throw AppFailure("Fixture requires a new directory, never your home") }
            let p = AppPaths(home: home)
            let games = [(620, "Portal 2"), (400, "Portal"), (480, "Spacewar")]
            var config = MacSteamConfig()
            for (id, name) in games {
                let raw = "-- UI TEST FIXTURE ONLY\naddappid(\(id)) -- \(name)\n"
                let doc = try LuaDocument.parse(raw)
                try config.merge(doc)
                try FileStore.write(Data(raw.utf8), to: p.lua.appendingPathComponent("\(id).lua"))
            }
            try FileStore.write(Data(config.serialized().utf8), to: p.config)
            var prefs = Preferences(); prefs.autoMetadata = false
            try FileStore.json(prefs, to: p.settings)
            print("Fixture created: \(home.path)")
            return
        }
        if args.first == "--network" {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FluentNetwork-\(UUID().uuidString)")
            defer { try? FileStore.fm.removeItem(at: temporary) }
            let api = SteamAPI(cache: temporary)
            let found = try await api.search("Portal")
            guard found.contains(where: { $0.id == 620 }) else { throw AppFailure("Store search did not return Portal 2") }
            print("PASS: live Steam search (\(found.count) results)")
            let detail = try await api.details(620)
            guard detail.id == 620, !detail.name.isEmpty else { throw AppFailure("Store detail failed") }
            print("PASS: live Steam localized metadata: \(detail.name)")
            let info = try await api.appInfo(620)
            guard !info.depots.isEmpty else { throw AppFailure("No depot data") }
            print("PASS: live depot query (\(info.depots.count) depots)")
            return
        }
        if args.first == "--manifest", args.count == 2, let id = TextUtil.validID(args[1]) {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FluentManifest-\(UUID().uuidString)")
            defer { try? FileStore.fm.removeItem(at: temporary) }
            let api = SteamAPI(cache: temporary)
            let info = try await api.appInfo(id)
            guard let depot = info.depots.first(where: { !$0.manifest.isEmpty }) else { throw AppFailure("No public manifest") }
            let data = try await ContentService(api: api, cache: temporary).fetchManifest(depot: depot.id, manifest: depot.manifest, template: Preferences().manifestURL)
            print("PASS: live manifest \(depot.id)_\(depot.manifest), \(data.count) bytes, framing / identity / CRC verified. No Steam files modified.")
            return
        }
        let p = AppPaths(); let runtime = RuntimeStatus.read(p)
        let games = try SteamLibrary.games(p)
        let report: [String: Any] = [
            "steamInstalled": runtime.steamInstalled,
            "steamBuild": runtime.build,
            "macSteamVersion": runtime.macSteamVersion,
            "notProtonVersion": runtime.notProtonVersion,
            "bothInjected": runtime.bothInjected,
            "missingDylibs": runtime.missingLibraries.count,
            "macSteamSignaturesFound": runtime.macSteamSignature,
            "notProtonSignaturesFound": runtime.notProtonSignature,
            "macSteamCurrentProcess": runtime.macSteamLoaded,
            "notProtonCurrentProcess": runtime.notProtonLoaded,
            "manifestPinsCurrentProcess": runtime.manifestPinsLoaded,
            "runtimeWarnings": runtime.runtimeWarnings,
            "runners": runtime.runners.count,
            "prefixes": runtime.prefixCount,
            "libraryFolders": SteamLibrary.libraries(p).count,
            "games": games.count,
            "enabledEntries": games.filter(\.enabled).count
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
