import Testing
import Foundation
import ZIPFoundation
@testable import MacSteamToolCore

@Suite("MacSteamTool core")
final class CoreTests {
    let key = String(repeating: "a1", count: 32)
    var temp: URL!
    init() throws {
        temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentTests-\(UUID().uuidString)")
        try FileStore.mkdir(temp)
    }
    deinit { if let temp { try? FileManager.default.removeItem(at: temp) } }

    @Test func dataDirectoryForNewAndExistingInstallations() throws {
        let support = temp.appendingPathComponent("Library/Application Support")
        let current = support.appendingPathComponent("MacSteamTool"), legacy = support.appendingPathComponent("FluentSteamMac")
        #expect(AppPaths(home: temp).data.path == current.path)
        try FileStore.mkdir(legacy)
        #expect(AppPaths(home: temp).data.path == legacy.path)
        try FileStore.mkdir(current)
        #expect(AppPaths(home: temp).data.path == current.path)
        let custom = temp.appendingPathComponent("custom")
        #expect(AppPaths(home: temp, data: custom).data == custom)
    }
    func fixture() throws -> AppPaths {
        let p = AppPaths(home: temp)
        try FileStore.write(Data("HideWhatsNew: yes\n\nFutureFlag: 123\n".utf8), to: p.config)
        return p
    }
    func lua(_ id: Int = 480) -> String { "-- test\naddappid(\(id)) -- 测试游戏\naddappid(481, 1, \"\(key)\")\naddappid(482) -- DLC\naddappid(483,1,'\(key)')\n" }

    @Test func patchInstallRestoreAndConflictProtection() throws {
        let p = try fixture(), game = temp.appendingPathComponent("game"), package = temp.appendingPathComponent("patch")
        try FileStore.write(Data("original".utf8), to: game.appendingPathComponent("steam_api64.dll"))
        try FileStore.write(Data("patched".utf8), to: package.appendingPathComponent("steam_api64.dll"))
        try FileStore.write(Data("480".utf8), to: package.appendingPathComponent("steam_settings/steam_appid.txt"))
        let plan = try GamePatches.plan(package: package, gameRoot: game, appID: 480)
        assertEqual(plan.entries.count, 2); assertEqual(plan.entries.filter(\.replacing).count, 1)
        let receipt = try GamePatches.install(plan, paths: p)
        assertEqual(try FileStore.text(game.appendingPathComponent("steam_api64.dll")), "patched")
        try FileStore.write(Data("game update".utf8), to: game.appendingPathComponent("steam_api64.dll"))
        expectThrow(try GamePatches.restore(receipt, paths: p))
        assertEqual(try FileStore.text(game.appendingPathComponent("steam_api64.dll")), "game update")
        try FileStore.write(Data("patched".utf8), to: game.appendingPathComponent("steam_api64.dll"))
        try GamePatches.restore(receipt, paths: p)
        assertEqual(try FileStore.text(game.appendingPathComponent("steam_api64.dll")), "original")
        assertFalse(FileStore.fm.fileExists(atPath: game.appendingPathComponent("steam_settings/steam_appid.txt").path))
        assertTrue(try requireValue(GamePatches.receipts(paths: p).first).restored)
    }
    @Test func patchRejectsSymlinksAndPreviewConflicts() throws {
        let p = try fixture(), game = temp.appendingPathComponent("game"), package = temp.appendingPathComponent("patch"), outside = temp.appendingPathComponent("outside")
        try FileStore.mkdir(game); try FileStore.mkdir(outside)
        try FileStore.write(Data("new".utf8), to: package.appendingPathComponent("nested/file.dll"))
        try FileStore.fm.createSymbolicLink(at: game.appendingPathComponent("nested"), withDestinationURL: outside)
        expectThrow(try GamePatches.plan(package: package, gameRoot: game, appID: 480))
        try FileStore.fm.removeItem(at: game.appendingPathComponent("nested"))
        let plan = try GamePatches.plan(package: package, gameRoot: game, appID: 480)
        try FileStore.write(Data("concurrent".utf8), to: game.appendingPathComponent("nested/file.dll"))
        expectThrow(try GamePatches.install(plan, paths: p))
        assertEqual(try FileStore.text(game.appendingPathComponent("nested/file.dll")), "concurrent")
        expectThrow(try GamePatches.target("../escape.dll", root: game))
    }

    @Test func kernelMergePreservesOtherRuntimesAndEnvironment() throws {
        let path = "/Applications/Steam.app/Contents/MacOS/"
        let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleName": "Steam", "LSEnvironment": ["DYLD_INSERT_LIBRARIES": path + "macsteam.dylib:" + path + "notproton.dylib", "KeepThis": "yes"]]
        let original = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let installed = try KernelDeployment.mergedPlist(original, library: path + "cloud_redirect.dylib", install: true)
        let repeatInstall = try KernelDeployment.mergedPlist(installed, library: path + "cloud_redirect.dylib", install: true)
        assertEqual(installed, repeatInstall)
        let removed = try KernelDeployment.mergedPlist(installed, library: path + "cloud_redirect.dylib", install: false)
        let roundtrip = try PropertyListSerialization.propertyList(from: removed, format: nil) as! NSDictionary
        assertEqual(roundtrip, plist as NSDictionary)
        expectThrow(try KernelDeployment.mergedPlist(original, library: path + "untrusted.dylib", install: true))
    }


    @Test func runtimeEvidenceRejectsOldProcessAndReportsFallbackHooks() {
        let log = """
        loaded into steam_osx (pid 10)
        ready, 13/13 hooks installed
        loaded into steam_osx (pid 20)
        sigdb: loaded fallback
        resolver: steamclient.dylib 18/18 signatures resolved, 3/3 optional
        install_thread: ready, 13/13 hooks installed
        warn compatsvc: cannot rebuild
        """
        assertTrue(RuntimeEvidence.parse(log, pid: 30).summary.isEmpty)
        assertTrue(RuntimeEvidence.parse(log, pid: 20).summary.contains("18/18 signatures"))
        assertEqual(RuntimeEvidence.parse(log, pid: 20).warnings.count, 1)
        assertFalse(RuntimeEvidence.parse(log, pid: 10).summary.contains("18/18"))
    }

    @Test func testLuaCommentsKeysOwnershipAndPins() throws {
        let doc = try LuaDocument.parse(lua() + "-- addappid(999)\n--[[\naddappid(888)\n]]\n-- setManifestid(481,\"1234\",0)\nsetManifestid(483,'18446744073709551615',0)\naddtoken(480,'123')")
        assertEqual(doc.appID, 480); assertEqual(doc.dlcIDs, [482]); assertEqual(doc.depots.map(\.owner), [480, 482])
        assertEqual(doc.pins.count, 2); assertEqual(doc.pins.first?.active, false)
        assertEqual(doc.pins.last?.manifest, "18446744073709551615"); assertEqual(doc.tokens[480], "123")
        assertEqual(doc.warnings.count, 2)
    }
    @Test func testLuaRejectsMalformedKeyAndIdentityMismatch() throws {
        expectThrow(try LuaDocument.parse("addappid(480)\naddappid(481,1,'deadbeef')"))
        expectThrow(try LuaDocument.parse(lua(), suggestedID: 999))
        expectThrow(try LuaDocument.parse("addappid(999999999999999999999999)"))
    }
    @Test func testPinEditingPreservesOtherContent() throws {
        let doc = try LuaDocument.parse(lua() + "-- setManifestid(481,'1234')\n-- a note\n")
        let pinned = try doc.pinning([481: "456"])
        assertEqual(pinned.pins, [ManifestPin(depot: 481, manifest: "456", active: true)])
        assertTrue(pinned.raw.contains("-- a note")); assertEqual(try pinned.pinning(nil).pins.count, 0)
    }
    @Test func testConfigPreservesUnknownAndRoundTrips() throws {
        var config = try MacSteamConfig.parse("HideWhatsNew: yes\nCustomFeature:\n  enabled: true\n")
        try config.merge(LuaDocument.parse(lua()))
        let reread = try MacSteamConfig.parse(config.serialized())
        assertEqual(reread.apps, [480, 482]); assertEqual(reread.parents[482], 480)
        assertEqual(reread.keys[482]?[483], key); assertTrue(reread.hideWhatsNew)
        assertTrue(reread.serialized().contains("CustomFeature:\n  enabled: true"))
        assertEqual(try LuaDocument.parse(config.lua(for: 480)).dlcIDs, [482])
    }
    @Test func testConfigRejectsUnknownSyntaxInManagedBlocks() {
        expectThrow(try MacSteamConfig.parse("Apps: [480, 482]\n"))
        expectThrow(try MacSteamConfig.parse("Apps:\n - 480\n"))
    }
    @Test func nativeManifestPinsFollowLibraryTransactionsAndPreserveUInt64() throws {
        let p = try fixture()
        let isolated = LibraryService(paths: p)
        let content = lua() + "setManifestid(481,'18446744073709551615',0)\n-- setManifestid(483,'123')\n"
        try isolated.perform(isolated.plan([ImportFile(name: "480.lua", data: Data(content.utf8))]))
        var config = try MacSteamConfig.parse(FileStore.text(p.config))
        assertEqual(config.manifestPins[480], [481: "18446744073709551615"])
        assertEqual(try LuaDocument.parse(config.lua(for: 480)).pins.first?.manifest, "18446744073709551615")
        var game = try requireValue(SteamLibrary.games(p).first(where: { $0.id == 480 }))
        try isolated.setEnabled(game, enabled: false)
        assertTrue(try MacSteamConfig.parse(FileStore.text(p.config)).manifestPins.isEmpty)
        game = try requireValue(SteamLibrary.games(p).first(where: { $0.id == 480 }))
        try isolated.setEnabled(game, enabled: true)
        game = try requireValue(SteamLibrary.games(p).first(where: { $0.id == 480 }))
        assertEqual(try MacSteamConfig.parse(FileStore.text(p.config)).manifestPins[480]?[481], "18446744073709551615")
        try isolated.saveLua(lua(), game: game)
        config = try MacSteamConfig.parse(FileStore.text(p.config))
        assertTrue(config.manifestPins.isEmpty)
        assertTrue(config.serialized().contains("FutureFlag: 123"))
        let beforeKeys = config.keys
        try FileStore.write(Data(content.utf8), to: try requireValue(game.luaURL))
        try isolated.synchronizeManifestPins()
        config = try MacSteamConfig.parse(FileStore.text(p.config))
        assertEqual(config.keys, beforeKeys)
        assertEqual(config.manifestPins[480]?[481], "18446744073709551615")
    }
    @Test func nativeManifestPinsRejectInvalidAndConflictingVersions() throws {
        let invalid = ["0", "18446744073709551616", "no"]
        for value in invalid { expectThrow(try MacSteamConfig.parse("FluentManifestPins:\n  480:\n    481: \(value)\n")) }
        expectThrow(try MacSteamConfig.parse("FluentManifestPins:\n  480:\n    481: 123\n  482:\n    481: 456\n"))
        var config = MacSteamConfig()
        expectThrow(try config.merge(LuaDocument.parse("addappid(480)\nsetManifestid(481,'1')\nsetManifestid(481,'2')\n")))
    }
    @Test func testVDFNestedEscapesAndCommentsRoundTrip() throws {
        let text = #""libraryfolders" { "0" { "path" "/Volumes/My Games/Steam" "label" "a \"quoted\" name" } } // comment"#
        let doc = try VDF.parse(text)
        assertEqual(doc.object("libraryfolders")?.object("0")?.string("path"), "/Volumes/My Games/Steam")
        assertEqual(try VDF.parse(doc.serialized()), doc)
        expectThrow(try VDF.parse("\"broken\" { \"key\" \"value\""))
    }
    @Test func testImportDisableEnableExportAndRestore() throws {
        let p = try fixture(); let original = try FileStore.read(p.config)
        let service = LibraryService(paths: p)
        try service.perform(service.plan([ImportFile(name: "480.lua", data: Data(lua().utf8))]))
        var game = try requireValue(SteamLibrary.games(p).first)
        assertTrue(game.enabled); assertEqual(game.dlcIDs, [482])
        assertTrue(try FileStore.text(p.config).contains("FutureFlag: 123"))
        try service.setEnabled(game, enabled: false)
        game = try requireValue(SteamLibrary.games(p).first)
        assertFalse(game.enabled); assertEqual(game.luaURL?.deletingLastPathComponent().resolvingSymlinksInPath().path, p.disabled.resolvingSymlinksInPath().path)
        assertFalse(try MacSteamConfig.parse(FileStore.text(p.config)).apps.contains(482))
        try service.setEnabled(game, enabled: true)
        game = try requireValue(SteamLibrary.games(p).first)
        assertTrue(game.enabled)
        let zip = temp.appendingPathComponent("export.zip"); try service.export([game], to: zip)
        let files = try ArchiveIO.importFiles([zip]); assertEqual(files.count, 1); assertEqual(String(decoding: files[0].data, as: UTF8.self), lua())
        let journal = FileTransaction(backupRoot: p.backups)
        let first = try requireValue(journal.records().last)
        try journal.restore(first, allowedRoots: [p.macSteam, p.lua, p.steam, AutomaticCompatibility.file(p), AutomaticAchievements.file(p)])
        assertTrue(try AutomaticCompatibility.state(paths: p).jobs.isEmpty)
        assertTrue(try AutomaticAchievements.state(paths: p).jobs.isEmpty)
        assertEqual(try FileStore.read(p.config), original)
        assertFalse(FileStore.fm.fileExists(atPath: p.lua.appendingPathComponent("480.lua").path))
    }
    @Test func testOptimisticConflictLeavesFileUnchanged() throws {
        let p = try fixture(); let before = try FileStore.read(p.config)
        let journal = FileTransaction(backupRoot: p.backups)
        expectThrow(try journal.apply([(p.config, Data("replacement".utf8))], reason: "conflict", expectations: [p.config: "wrong hash"]))
        assertEqual(try FileStore.read(p.config), before); assertTrue(journal.records().isEmpty)
    }
    @Test func testFailedBatchRestoresAlreadyWrittenFiles() throws {
        let first = temp.appendingPathComponent("a.txt"); try FileStore.write(Data("before".utf8), to: first)
        let blocker = temp.appendingPathComponent("z"); try FileStore.write(Data("not a directory".utf8), to: blocker)
        let impossible = blocker.appendingPathComponent("file.txt")
        expectThrow(try FileTransaction(backupRoot: temp.appendingPathComponent("Backups")).apply([(first, Data("after".utf8)), (impossible, Data())], reason: "failure"))
        assertEqual(try FileStore.text(first), "before")
    }
    @Test func testZipRejectsTraversalAndSymlinks() throws {
        for type in [Entry.EntryType.file, .symlink] {
            let zip = temp.appendingPathComponent("bad-\(UUID()).zip")
            let archive = try Archive(url: zip, accessMode: .create)
            let content = Data(lua().utf8)
            try archive.addEntry(with: type == .file ? "../480.lua" : "480.lua", type: type, uncompressedSize: Int64(content.count)) { position, size in content.subdata(in: Int(position)..<(Int(position) + size)) }
            expectThrow(try ArchiveIO.importFiles([zip]))
        }
    }
    @Test func testTamperedBackupRefusesRestore() throws {
        let p = try fixture(); let journal = FileTransaction(backupRoot: p.backups)
        let record = try journal.apply([(p.config, Data("HideWhatsNew: no\n".utf8))], reason: "test")
        try FileStore.write(Data("corrupt".utf8), to: p.backups.appendingPathComponent(record.id).appendingPathComponent(record.files[0].stored))
        expectThrow(try journal.restore(record, allowedRoots: [p.macSteam]))
        assertEqual(try FileStore.text(p.config), "HideWhatsNew: no\n")
    }
    @Test func testMultiLibraryAndPrefixDiscovery() throws {
        let p = try fixture(); let external = temp.appendingPathComponent("External Steam")
        let vdf = "\"libraryfolders\" { \"0\" { \"path\" \"\(p.steam.path)\" } \"1\" { \"path\" \"\(external.path)\" } }"
        try FileStore.write(Data(vdf.utf8), to: p.steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let manifest = "\"AppState\" { \"appid\" \"480\" \"name\" \"Spacewar\" \"installdir\" \"Spacewar\" \"buildid\" \"42\" \"InstalledDepots\" { \"481\" { \"manifest\" \"123456789123456789\" } } }"
        try FileStore.write(Data(manifest.utf8), to: external.appendingPathComponent("steamapps/appmanifest_480.acf"))
        try FileStore.mkdir(external.appendingPathComponent("steamapps/compatdata/480/pfx"))
        assertEqual(SteamLibrary.libraries(p).count, 2)
        let installed = try requireValue(SteamLibrary.installed(p).first)
        assertEqual(installed.library.path, external.path); assertEqual(installed.depots[481], "123456789123456789")
        assertEqual(SteamLibrary.prefixes(p).first?.id, 480)
    }
    @Test func testSaveBackupVerificationAndSymlinkRefusal() throws {
        let saves = temp.appendingPathComponent("saves"); let destination = temp.appendingPathComponent("copy")
        try FileStore.write(Data("progress".utf8), to: saves.appendingPathComponent("nested/save.dat"))
        assertEqual(try Saves.backup(saves, to: destination), 1)
        assertEqual(try FileStore.text(destination.appendingPathComponent("nested/save.dat")), "progress")
        assertTrue(FileStore.fm.fileExists(atPath: destination.appendingPathComponent(".fluent-checksums.json").path))
        try FileStore.fm.createSymbolicLink(at: saves.appendingPathComponent("link"), withDestinationURL: temp)
        expectThrow(try Saves.backup(saves, to: temp.appendingPathComponent("copy2")))
    }
    @Test func testNativeAccountSwitchPreservesUnrelatedRegistry() throws {
        let p = try fixture()
        try FileStore.write(Data(#""users" { "1" { "AccountName" "first" "PersonaName" "One" "MostRecent" "1" } "2" { "AccountName" "second" "PersonaName" "Two" "MostRecent" "0" } }"#.utf8), to: p.steam.appendingPathComponent("config/loginusers.vdf"))
        try FileStore.write(Data(#""Registry" { "HKCU" { "Software" { "Valve" { "Steam" { "AutoLoginUser" "first" "Other" "preserve" } } } } }"#.utf8), to: p.steam.appendingPathComponent("registry.vdf"))
        let second = try requireValue(Accounts.list(p).last); try Accounts.select(second, paths: p)
        assertEqual(try Accounts.list(p).first(where: \.recent)?.id, "2")
        let registry = try FileStore.text(p.steam.appendingPathComponent("registry.vdf"))
        assertTrue(registry.contains("second")); assertTrue(registry.contains("preserve"))
    }
    @Test func testRuntimeReadsSignedSteamManifestAndBothLibraries() throws {
        var p = try fixture(); p.steamApp = temp.appendingPathComponent("Steam.app")
        let dylibs = ["macsteam", "notproton"].map { p.steamApp.appendingPathComponent("Contents/MacOS/\($0).dylib") }
        for dylib in dylibs { try FileStore.write(Data(), to: dylib) }
        let plist: [String: Any] = ["LSEnvironment": ["DYLD_INSERT_LIBRARIES": dylibs.map(\.path).joined(separator: ":")]]
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: p.steamApp.appendingPathComponent("Contents/Info.plist"))
        try FileStore.write(Data("\"osx\" { \"version\" \"1792618285\" }".utf8), to: p.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/package/steam_client_signed-2_osx.manifest"))
        for root in [p.macSteam, p.notProton] { try FileStore.write(Data("{}".utf8), to: root.appendingPathComponent("signatures/macos.arm64/1792618285.json")) }
        let status = RuntimeStatus.read(p)
        assertTrue(status.bothInjected); assertEqual(status.build, "1792618285"); assertTrue(status.macSteamSignature); assertTrue(status.notProtonSignature)
    }
    @Test func testWineUsesMatchingRunnerAndRefusesMissingBuild() throws {
        let p = try fixture(); let prefix = p.steam.appendingPathComponent("steamapps/compatdata/480/pfx")
        try FileStore.mkdir(prefix)
        try FileStore.write(Data("26.3.0.39832\nRosetta\n".utf8), to: prefix.deletingLastPathComponent().appendingPathComponent("notproton-build"))
        expectThrow(try WineLaunch.prepare(appID: 480, command: "/example/tool.exe", paths: p))
        let runner = p.notProton.appendingPathComponent("runners/crossover-26.3.0.39832/CrossOver")
        for name in ["lib/wine/x86_64-unix/wine", "bin/wineserver"] {
            let file = runner.appendingPathComponent(name); try FileStore.write(Data("#!/bin/sh\nexit 0\n".utf8), to: file)
            try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let client = p.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS")
        let bridge = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileStore.write(Data(), to: client.appendingPathComponent("steamclient.dylib"))
        try FileStore.write(Data(), to: bridge.appendingPathComponent("lsteamclient.so"))
        let launch = try WineLaunch.prepare(appID: 480, command: "/example/tool.exe", paths: p)
        assertEqual(launch.environment["WINEPREFIX"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, prefix.resolvingSymlinksInPath().path)
        assertEqual(launch.arguments, ["/example/tool.exe"])
        assertEqual(launch.executable.path, runner.appendingPathComponent("lib/wine/x86_64-unix/wine").path)
        assertEqual(launch.environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"], client.path)
        assertEqual(launch.environment["SteamAppId"], "480")
        let firstDLLPath = launch.environment["WINEDLLPATH"]?.components(separatedBy: ":").first
        #expect(firstDLLPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == bridge.resolvingSymlinksInPath().path)
        assertTrue(launch.environment["WINEDLLOVERRIDES"]?.contains("lsteamclient=b") == true)
    }
    @Test func testManifestFramingIdentityAndCRC() throws {
        let data = manifestFixture()
        try SteamManifest.validate(data, depot: 481, manifest: "9123456789123456789")
        expectThrow(try SteamManifest.validate(data, depot: 482, manifest: "9123456789123456789"))
        expectThrow(try SteamManifest.validate(data, depot: 481, manifest: "123"))
        expectThrow(try SteamManifest.validate(data.dropLast(), depot: 481, manifest: "9123456789123456789"))
        expectThrow(try SteamManifest.validate(data, depot: -1, manifest: "no"))
        expectThrow(try SteamManifest.validate(manifestFixture(crc: 123), depot: 481, manifest: "9123456789123456789"))
        assertEqual(SteamManifest.crc32([0, 0, 0, 0]), 0x2144df1c)
        let p = try fixture()
        _ = try LibraryService(paths: p).plan([ImportFile(name: "481_9123456789123456789.manifest", data: data)])
        expectThrow(try LibraryService(paths: p).plan([ImportFile(name: "482_9123456789123456789.manifest", data: data)]))
    }
    @Test func testLogTailPartialLinesDeduplicationAndRotation() throws {
        let log = temp.appendingPathComponent("content_log.txt")
        let line = "BYldRequestDepotManifest(App: 480, Depot: 481, Manifest: 9123456789123456789)\n"
        try FileStore.write(Data(line.utf8), to: log)
        var tail = try ContentLogTail(url: log)
        assertTrue(try tail.poll().isEmpty)
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.dropLast().utf8))
        assertTrue(try tail.poll().isEmpty)
        try handle.write(contentsOf: Data("\n".utf8)); try handle.close()
        assertEqual(try tail.poll().first?.manifest, "9123456789123456789")
        try FileStore.write(Data((line + line.replacingOccurrences(of: "481", with: "482")).utf8), to: log)
        let requests = try tail.poll()
        assertEqual(requests.count, 1); assertEqual(requests.first?.depot, 482)
    }
    @Test func testSaveRestoreReplacesAndBacksUpPreviousThenClear() throws {
        let source = temp.appendingPathComponent("source"), backup = temp.appendingPathComponent("snapshot")
        let target = temp.appendingPathComponent("target"), history = temp.appendingPathComponent("history")
        try FileStore.write(Data("level 1".utf8), to: source.appendingPathComponent("nested/save.dat"))
        _ = try Saves.backup(source, to: backup)
        try FileStore.write(Data("level 9".utf8), to: target.appendingPathComponent("newer.dat"))
        let restored = try Saves.restore(backup, to: target, backupRoot: history)
        assertEqual(restored.files, 1)
        assertEqual(try FileStore.text(target.appendingPathComponent("nested/save.dat")), "level 1")
        assertFalse(FileStore.fm.fileExists(atPath: target.appendingPathComponent("newer.dat").path))
        assertEqual(try FileStore.text(requireValue(restored.previousBackup).appendingPathComponent("newer.dat")), "level 9")
        let cleared = try Saves.clear(target, backupRoot: history)
        assertTrue(FileStore.files(target).isEmpty)
        assertEqual(try Saves.verifyBackup(requireValue(cleared.previousBackup)).count, 1)
    }
    @Test func testSaveRestoreRejectsCorruptUnsafeAndUnlistedFiles() throws {
        let source = temp.appendingPathComponent("source"), backup = temp.appendingPathComponent("snapshot")
        let target = temp.appendingPathComponent("target"), history = temp.appendingPathComponent("history")
        try FileStore.write(Data("original".utf8), to: source.appendingPathComponent("save.dat"))
        _ = try Saves.backup(source, to: backup)
        try FileStore.write(Data("keep".utf8), to: target.appendingPathComponent("keep.dat"))
        try FileStore.write(Data("extra".utf8), to: backup.appendingPathComponent("extra.dat"))
        expectThrow(try Saves.restore(backup, to: target, backupRoot: history))
        assertEqual(try FileStore.text(target.appendingPathComponent("keep.dat")), "keep")
        try FileStore.fm.removeItem(at: backup.appendingPathComponent("extra.dat"))
        try FileStore.write(Data("tampered".utf8), to: backup.appendingPathComponent("save.dat"))
        expectThrow(try Saves.restore(backup, to: target, backupRoot: history))
        try FileStore.json(["../target/keep.dat": FileStore.hash(Data("keep".utf8))], to: backup.appendingPathComponent(".fluent-checksums.json"))
        expectThrow(try Saves.verifyBackup(backup))
    }
    @Test func testRestoreRefusesAncestorSymlinkEscape() throws {
        let root = temp.appendingPathComponent("allowed"), outside = temp.appendingPathComponent("outside")
        try FileStore.mkdir(root); try FileStore.mkdir(outside)
        try FileStore.fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let target = root.appendingPathComponent("link/file.txt")
        let journal = FileTransaction(backupRoot: temp.appendingPathComponent("Backups"))
        let record = try journal.apply([(target, Data("keep".utf8))], reason: "fixture")
        expectThrow(try journal.restore(record, allowedRoots: [root]))
        assertEqual(try FileStore.text(target), "keep")
    }
}

private func manifestFixture(crc: UInt64 = 0x2144df1c) -> Data {
    func vint(_ value: UInt64) -> [UInt8] {
        var n = value, result: [UInt8] = []
        while n >= 128 { result.append(UInt8(n & 0x7f) | 0x80); n >>= 7 }; result.append(UInt8(n)); return result
    }
    func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    let metadata = [UInt8(8)] + vint(481) + [16] + vint(9123456789123456789) + [72] + vint(crc)
    return Data(u32(0x71f617d0) + u32(0) + u32(0x1f4812be) + u32(UInt32(metadata.count)) + metadata + u32(0x1b81b817) + u32(0) + u32(0x32c415ab))
}

private func assertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { let lhs = try a(); let rhs = try b(); #expect(lhs == rhs, sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func assertTrue(_ value: @autoclosure () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try value(), sourceLocation: sourceLocation) } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func assertFalse(_ value: @autoclosure () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try !value(), sourceLocation: sourceLocation) } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func expectThrow<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: (any Error).self, sourceLocation: sourceLocation) { _ = try expression() }
}
private func requireValue<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

struct WineOverrideTests {
    @Test func scopedOverridesPreserveOtherApplicationsAndSettings() throws {
        let raw = "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\DllOverrides] 1\n\"winmm\"=\"builtin\"\n\n[Software\\\\Wine\\\\AppDefaults\\\\Game.exe\\\\DllOverrides] 1\n\"version\"=\"builtin\"\n\"other\"=\"native\"\n\n[Unrelated] 1\n\"value\"=\"keep\"\n"
        let updated = try WineOverrides.edit(Data(raw.utf8), executable: "Game.exe", libraries: ["version", "WINHTTP"])
        let text = String(decoding: updated, as: UTF8.self)
        #expect(text.contains("\"version\"=\"native,builtin\""))
        #expect(text.contains("\"winhttp\"=\"native,builtin\""))
        #expect(text.contains("\"winmm\"=\"builtin\""))
        #expect(text.contains("\"other\"=\"native\""))
        #expect(text.contains("[Unrelated] 1\n\"value\"=\"keep\""))
        #expect(try WineOverrides.edit(updated, executable: "Game.exe", libraries: ["version", "winhttp"]) == updated)
        #expect(throws: (any Error).self) { try WineOverrides.edit(updated, executable: "../Game.exe", libraries: ["version"]) }
        #expect(throws: (any Error).self) { try WineOverrides.edit(updated, executable: "Game.exe", libraries: ["version.dll"]) }
    }
    @Test func newOverridesAreAppScopedAndAmbiguousEntriesAreRejected() throws {
        let updated = try WineOverrides.edit(Data("WINE REGISTRY Version 2\n\n".utf8), executable: "Game.exe", libraries: ["version"])
        let text = String(decoding: updated, as: UTF8.self)
        #expect(text.contains("[Software\\\\Wine\\\\AppDefaults\\\\Game.exe\\\\DllOverrides]"))
        let duplicate = text + "\n[Software\\\\Wine\\\\AppDefaults\\\\Game.exe\\\\DllOverrides] 1\n"
        #expect(throws: (any Error).self) { try WineOverrides.edit(Data(duplicate.utf8), executable: "Game.exe", libraries: ["version"]) }
    }
}

struct PatchRegistryTests {
    @Test func patchAndScopedWineConfigurationRestoreTogether() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentPatchRegistry-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root), game = root.appendingPathComponent("game"), payload = root.appendingPathComponent("payload")
        let registry = paths.steam.appendingPathComponent("steamapps/compatdata/480/pfx/user.reg")
        let original = Data("WINE REGISTRY Version 2\n\n".utf8)
        try FileStore.write(original, to: registry)
        try FileStore.write(Data([1,2,3]), to: payload.appendingPathComponent("version.dll"))
        var pe = Data(repeating: 0, count: 68); pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 64; pe[64] = 0x50; pe[65] = 0x45
        let exe = game.appendingPathComponent("Game.exe"); try FileStore.write(pe, to: exe)
        let plan = try GamePatches.plan(package: payload, gameRoot: game, appID: 480)
        let updated = try GamePatches.addingOverrides(to: plan, executable: exe, libraries: WineOverrides.suggested(plan), paths: paths)
        let receipt = try GamePatches.install(updated, paths: paths)
        #expect(receipt.registry != nil)
        #expect(try FileStore.text(registry).contains("native,builtin"))
        #expect(FileStore.fm.fileExists(atPath: game.appendingPathComponent("version.dll").path))
        try GamePatches.restore(receipt, paths: paths)
        #expect(try FileStore.read(registry) == original)
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("version.dll").path))
        #expect(try FileStore.read(exe) == pe)
    }
}

struct OfflineToolTests {
    private func pe(_ machine: UInt16, marker: UInt8) -> Data {
        var bytes = Data(repeating: 0, count: 128); bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = UInt8(machine & 255); bytes[69] = UInt8(machine >> 8); bytes[100] = marker
        return bytes
    }
    @Test func goldbergPreviewsBothArchitecturesAndRestoresWithoutTouchingSaves() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentGoldbergTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root), package = root.appendingPathComponent("tool"), game = root.appendingPathComponent("game")
        let assets = [
            "release/experimental/x86/steam_api.dll": pe(0x14c, marker: 1),
            "release/experimental/x64/steam_api64.dll": pe(0x8664, marker: 2),
            "release/regular/x86/steam_api.dll": pe(0x14c, marker: 5),
            "release/regular/x64/steam_api64.dll": pe(0x8664, marker: 6)
        ]
        for (path, data) in assets { try FileStore.write(data, to: package.appendingPathComponent("payload/" + path)) }
        try FileStore.json(ToolPackage(provider: "goldberg", version: "fixture", source: "fixture", archiveSHA256: "fixture", files: assets.mapValues(FileStore.hash)), to: package.appendingPathComponent("tool.json"))
        let original32 = pe(0x14c, marker: 3), original64 = pe(0x8664, marker: 4)
        try FileStore.write(original32, to: game.appendingPathComponent("legacy/steam_api.dll"))
        try FileStore.write(original64, to: game.appendingPathComponent("steam_api64.dll"))
        let save = game.appendingPathComponent("steam_settings/FluentOfflineSaves/480/save.bin"), saved = Data([0,2,255])
        try FileStore.write(saved, to: save)
        let config = game.appendingPathComponent("steam_settings/configs.user.ini"), oldConfig = Data("[user::general]\naccount_name=Existing\n".utf8)
        try FileStore.write(oldConfig, to: config)
        let overlayConfig = game.appendingPathComponent("steam_settings/configs.overlay.ini")
        let existingOverlay = Data("[overlay::general]\nenable_experimental_overlay=0\n".utf8)
        try FileStore.write(existingOverlay, to: overlayConfig)
        var schema = try OfflineSchema.parse(Data(#"{"game":{"availableGameStats":{"achievements":[{"name":"TEST","hidden":1,"icon":"https://cdn.akamai.steamstatic.com/480/test.png"}]}}}"#.utf8))
        let imagePath = try #require(OfflineSchema.imagePath(schema.definitions[0].icon))
        schema.images[imagePath] = Data([137,80,78,71])
        let plan = try OfflineTools.goldberg(package: package, gameRoot: game, appID: 480, dlcs: [481], accountName: "Fixture", language: "english", achievements: [Achievement(id: "TEST", name: "Test", detail: "Fixture", achieved: true, unlockedAt: 1)], schema: schema, destination: root.appendingPathComponent("stage"))
        #expect(plan.entries.filter(\.replacing).count == 4)
        let receipt = try GamePatches.install(plan, paths: paths)
        #expect(try FileStore.read(game.appendingPathComponent("steam_api64.dll")) == assets["release/experimental/x64/steam_api64.dll"])
        #expect(try FileStore.read(game.appendingPathComponent("legacy/steam_api.dll")) == assets["release/experimental/x86/steam_api.dll"])
        let enabledOverlay = "[overlay::general]\nenable_experimental_overlay=1\ndisable_achievement_notification=0\n"
        #expect(try FileStore.text(overlayConfig) == enabledOverlay)
        #expect(try FileStore.text(game.appendingPathComponent("legacy/steam_settings/configs.overlay.ini")) == enabledOverlay)
        #expect(try FileStore.text(game.appendingPathComponent("steam_settings/configs.app.ini")).contains("481=DLC 481"))
        #expect(try FileStore.text(game.appendingPathComponent("steam_settings/configs.main.ini")).contains("disable_networking=1"))
        #expect(try !FileStore.text(game.appendingPathComponent("steam_settings/achievements.json")).contains("achieved"))
        #expect(try FileStore.read(game.appendingPathComponent("steam_settings/" + imagePath)) == schema.images[imagePath])
        #expect(try FileStore.read(game.appendingPathComponent("legacy/steam_settings/" + imagePath)) == schema.images[imagePath])
        #expect(try FileStore.read(save) == saved)
        try GamePatches.restore(receipt, paths: paths)
        #expect(try FileStore.read(game.appendingPathComponent("steam_api64.dll")) == original64)
        #expect(try FileStore.read(config) == oldConfig)
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("steam_settings/" + imagePath).path))
        #expect(try FileStore.read(save) == saved)
        #expect(try FileStore.read(overlayConfig) == existingOverlay)
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("legacy/steam_settings/configs.overlay.ini").path))
        let definitions = try await OfflineTools.definitions(appID: 480, language: "english", apiKey: "  \n ", achievements: true, images: true, inventory: true, importedInventory: nil)
        let plain = try OfflineTools.goldberg(package: package, gameRoot: game, appID: 480, dlcs: [], accountName: "Fixture", language: "english", achievements: nil, inventory: definitions.inventory, schema: definitions.schema, overlay: false, destination: root.appendingPathComponent("plain"))
        #expect(plain.entries.allSatisfy { !$0.relative.hasSuffix(".json") && !$0.relative.hasSuffix("configs.overlay.ini") })
        let plainReceipt = try GamePatches.install(plain, paths: paths)
        #expect(try FileStore.read(game.appendingPathComponent("steam_api64.dll")) == assets["release/regular/x64/steam_api64.dll"])
        try GamePatches.restore(plainReceipt, paths: paths)
    }
    @Test func toolFilesAndPEHeadersAreValidated() throws {
        #expect(try OfflineTools.machine(pe(0x8664, marker: 0)) == 0x8664)
        #expect(throws: (any Error).self) { try OfflineTools.machine(Data("MachO is not PE".utf8)) }
        #expect(throws: (any Error).self) { try OfflineTools.machine(pe(0xaa64, marker: 0)) }
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentToolHash-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let bytes = pe(0x8664, marker: 0)
        let tool = ToolPackage(provider: "goldberg", version: "fixture", source: "fixture", archiveSHA256: "fixture", files: ["steam_api64.dll": FileStore.hash(bytes)])
        try FileStore.write(Data("changed".utf8), to: root.appendingPathComponent("payload/steam_api64.dll"))
        #expect(throws: (any Error).self) { try tool.file(ending: "steam_api64.dll", in: root) }
    }
}
