import Foundation
import FluentCore

/// Read-only diagnostics. Fixture creation is explicit and never targets the real home.
@main struct Inspect {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
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
            let target = root.appendingPathComponent("Fluent Steam Mac.app")
            try FileStore.fm.copyItem(at: prepared.application, to: target)
            let info = target.appendingPathComponent("Contents/Info.plist")
            var plist = try PropertyListSerialization.propertyList(from: FileStore.read(info), format: nil) as! [String: Any]
            plist["CFBundleVersion"] = "1"; plist["CFBundleShortVersionString"] = "0.1.0"
            try FileStore.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: info)
            let (sign, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--deep", "--sign", "-", target.path])
            guard sign == 0 else { throw AppFailure("Fixture signing failed") }
            let before = try AppUpdates.treeHash(target), after = try AppUpdates.treeHash(prepared.application)
            let plan = UpdateInstallPlan(source: prepared.application, target: target, expectedSource: after, expectedTarget: before, parentPID: 0, build: prepared.release.build)
            let planURL = root.appendingPathComponent("install.json"), helper = root.appendingPathComponent("FluentUpdater")
            try FileStore.json(plan, to: planURL)
            try FileStore.fm.copyItem(at: prepared.application.appendingPathComponent("Contents/MacOS/FluentUpdater"), to: helper)
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
