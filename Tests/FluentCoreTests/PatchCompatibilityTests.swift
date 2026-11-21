import Testing
import Foundation
@testable import FluentCore

@Suite struct PatchCompatibilityTests {
    func pe(_ arch: WindowsArchitecture, dll: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 512)
        func u16(_ i: Int, _ value: Int) { data[i] = UInt8(value & 255); data[i+1] = UInt8((value >> 8) & 255) }
        data[0] = 0x4d; data[1] = 0x5a; data[60] = 64; data[64] = 0x50; data[65] = 0x45
        u16(68, arch == .x64 ? 0x8664 : 0x14c); u16(70, 1); u16(84, arch == .x64 ? 240 : 224); u16(86, dll ? 0x2002 : 2); u16(88, arch == .x64 ? 0x20b : 0x10b)
        return data
    }
    func fixture() throws -> (URL, AppPaths, URL, URL, URL) {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentPatchPlatform-\(UUID())"), paths = AppPaths(home: root)
        let game = root.appendingPathComponent("Game"), exe = game.appendingPathComponent("Game.exe"), payload = root.appendingPathComponent("Payload")
        try FileStore.write(pe(.x64), to: exe); try FileStore.write(pe(.x64, dll: true), to: payload.appendingPathComponent("version.dll"))
        let prefix = paths.steam.appendingPathComponent("steamapps/compatdata/480/pfx")
        try FileStore.mkdir(prefix.appendingPathComponent("drive_c"))
        for name in ["user.reg", "system.reg"] { try FileStore.write(Data("WINE REGISTRY Version 2\n\n".utf8), to: prefix.appendingPathComponent(name)) }
        try FileStore.write(Data("fixture\nRosetta\n".utf8), to: prefix.deletingLastPathComponent().appendingPathComponent("notproton-build"))
        let runner = paths.notProton.appendingPathComponent("runners/crossover-fixture/CrossOver")
        for name in ["lib/wine/x86_64-unix/wine", "bin/wineserver"] {
            let file = runner.appendingPathComponent(name); try FileStore.write(Data("#!/bin/sh\nexit 0\n".utf8), to: file); try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (root, paths, game, exe, payload)
    }
    @Test func readsBothArchitecturesAndRejectsNativeTruncatedAndUnsupported() throws {
        #expect(try WindowsBinary.inspect(pe(.x86)).architecture == .x86)
        #expect(try WindowsBinary.inspect(pe(.x64, dll: true)).isDLL)
        for bytes in [Data([0xcf,0xfa,0xed,0xfe]), Data("plain".utf8), pe(.x64).prefix(90)] {
            #expect(throws: (any Error).self) { try WindowsBinary.inspect(Data(bytes)) }
        }
        var arm = pe(.x64); arm[68] = 0x64; arm[69] = 0xaa
        #expect(throws: (any Error).self) { try WindowsBinary.inspect(arm) }
        var wrong = pe(.x64); wrong[88] = 0x0b; wrong[89] = 1
        #expect(throws: (any Error).self) { try WindowsBinary.inspect(wrong) }
    }
    @Test func previewInstallRestoreBindGameAndRuntime() throws {
        let (root, paths, game, exe, payload) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let before = try FileStore.read(exe)
        let plan = try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths)
        #expect(plan.windowsTarget?.architecture == .x64)
        let updated = try GamePatches.addingOverrides(to: plan, executable: exe, libraries: ["version"], paths: paths)
        let receipt = try GamePatches.install(updated, paths: paths)
        #expect(receipt.windowsTarget != nil); #expect(receipt.executableSHA256 == FileStore.hash(before))
        try GamePatches.restore(receipt, paths: paths)
        #expect(try FileStore.read(exe) == before); #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("version.dll").path))
    }
    @Test func architectureNativeAndUnknownTargetsFailBeforeWrites() throws {
        let (root, paths, game, exe, payload) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        try FileStore.write(pe(.x86, dll: true), to: payload.appendingPathComponent("version.dll"))
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths) }
        try FileStore.write(Data([0xcf,0xfa,0xed,0xfe]), to: exe)
        do { _ = try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths); Issue.record("Native executable accepted") }
        catch { #expect(error.localizedDescription.contains("macOS")) }
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("version.dll").path))
        #expect(!FileStore.fm.fileExists(atPath: paths.data.appendingPathComponent("PatchBackups").path))
    }
    @Test func changedGameOrMissingBottleCannotInstall() throws {
        let (root, paths, game, exe, payload) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let plan = try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths)
        var changed = try FileStore.read(exe); changed[400] = 1; try FileStore.write(changed, to: exe)
        #expect(throws: (any Error).self) { try GamePatches.install(plan, paths: paths) }
        try FileStore.write(Data("WINE REGISTRY Version 2\n#arch=win32\n".utf8), to: URL(fileURLWithPath: plan.windowsTarget!.prefix).appendingPathComponent("system.reg"))
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths) }
        try FileStore.fm.removeItem(at: URL(fileURLWithPath: plan.windowsTarget!.prefix).appendingPathComponent("system.reg"))
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths) }
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("version.dll").path))
    }
    @Test func matchingX86AndExplicitCrossOverBottleAreSupported() throws {
        let (root, paths, game, exe, payload) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        try FileStore.write(pe(.x86), to: exe); try FileStore.write(pe(.x86, dll: true), to: payload.appendingPathComponent("version.dll"))
        let nativePlan = try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths)
        #expect(nativePlan.windowsTarget?.architecture == .x86)
        let application = root.appendingPathComponent("CrossOver.app"), support = application.appendingPathComponent("Contents/SharedSupport")
        try FileStore.mkdir(support)
        try FileStore.fm.createSymbolicLink(at: support.appendingPathComponent("CrossOver"), withDestinationURL: paths.notProton.appendingPathComponent("runners/crossover-fixture/CrossOver"))
        let bottle = URL(fileURLWithPath: nativePlan.windowsTarget!.prefix)
        let direct = try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths, bottle: bottle, crossOverApp: application)
        #expect(direct.windowsTarget?.kind == .crossOver); #expect(direct.windowsTarget?.architecture == .x86)
        try FileStore.write(pe(.x64, dll: true), to: payload.appendingPathComponent("version.dll"))
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths, bottle: bottle, crossOverApp: application) }
    }
    @Test func changedRunnerAndSymlinkedExecutableCannotInstall() throws {
        let (root, paths, game, exe, payload) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        let plan = try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths)
        try FileStore.fm.removeItem(at: URL(fileURLWithPath: plan.windowsTarget!.loader))
        #expect(throws: (any Error).self) { try GamePatches.install(plan, paths: paths) }
        let external = root.appendingPathComponent("outside.exe"); try FileStore.write(pe(.x64), to: external)
        try FileStore.fm.removeItem(at: exe); try FileStore.fm.createSymbolicLink(at: exe, withDestinationURL: external)
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths) }
        #expect(!FileStore.fm.fileExists(atPath: game.appendingPathComponent("version.dll").path))
    }
    @Test func rejectsMislabeledBinariesAndDrivers() throws {
        let (root, paths, game, exe, payload) = try fixture(); defer { try? FileStore.fm.removeItem(at: root) }
        try FileStore.write(pe(.x64), to: payload.appendingPathComponent("version.dll"))
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths) }
        try FileStore.write(pe(.x64, dll: true), to: payload.appendingPathComponent("version.dll"))
        try FileStore.write(pe(.x64), to: payload.appendingPathComponent("driver.sys"))
        #expect(throws: (any Error).self) { try GamePatches.windowsPlan(package: payload, gameRoot: game, appID: 480, executable: exe, paths: paths) }
    }
}
