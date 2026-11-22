import Foundation
import Testing
import Darwin
@testable import MacSteamToolCore

struct OneClickSetupTests {
    @Test func prepareRejectsProfileForTheToolWhenItCannotMatchSteam() async throws {
        guard #available(macOS 15, *) else { return }
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        var paths = AppPaths(home: root)
        paths.steamApp = root.appendingPathComponent("Steam.app")
        let info = ["CFBundleIdentifier": NativeSteamBootstrap.bundleIdentifier, "CFBundleExecutable": "steam_osx"]
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: paths.steamApp.appendingPathComponent("Contents/Info.plist"))
        let directory = paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS")
        let cpu = AppUpdates.architecture == "arm64" ? CPU_TYPE_X86_64 : CPU_TYPE_ARM64
        let header: [UInt32] = [MH_MAGIC_64, UInt32(cpu), 0, UInt32(MH_EXECUTE), 0, 0, 0, 0]
        try FileStore.write(header.withUnsafeBytes { Data($0) }, to: directory.appendingPathComponent("steam_osx"))
        try FileStore.write(Data(#""version" "123""#.utf8), to: directory.appendingPathComponent("package/steam_client_signed_osx.manifest"))
        let application = root.appendingPathComponent("Tool.app")
        let embedded = application.appendingPathComponent("Contents/Resources/RuntimeComponents/macsteam/0.8.2")
        try FileStore.write(Data("{}".utf8), to: embedded.appendingPathComponent("Resources/\(AppUpdates.nativeSignatureDirectory)/123.json"))
        let receipt = ManagedRuntimeComponent(provider: "macsteam", version: "0.8.2", source: "fixture",
            files: try ManagedRuntimeComponents.inventory(embedded), root: embedded)
        try FileStore.json(receipt, to: embedded.appendingPathComponent("component.json"))
        do {
            _ = try await OneClickSetup.prepare(paths: paths, options: SetupOptions(), application: application)
            Issue.record("Accepted a profile for a different client architecture")
        } catch {
            #expect(error.localizedDescription.contains("No integration profile for Steam 123"))
        }
    }
    @Test func guideDetectsAnInstalledSteamClient() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Steam.app")
        #expect(!NativeSteamBootstrap.isSteamApplication(app))
        let plist = app.appendingPathComponent("Contents/Info.plist")
        func writeBundle(_ identifier: String, executable: String) throws {
            let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable]
            try FileStore.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: plist)
        }
        try writeBundle(NativeSteamBootstrap.bundleIdentifier, executable: "steam_osx")
        #expect(!NativeSteamBootstrap.isSteamApplication(app))
        let binary = app.appendingPathComponent("Contents/MacOS/steam_osx")
        try FileStore.write(Data(), to: binary)
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(NativeSteamBootstrap.isSteamApplication(app))
        try writeBundle("example.other", executable: "steam_osx")
        #expect(!NativeSteamBootstrap.isSteamApplication(app))
        try writeBundle(NativeSteamBootstrap.bundleIdentifier, executable: "gameoverlayui")
        #expect(!NativeSteamBootstrap.isSteamApplication(app))
    }
    @Test func missingInternalComponentsNeverFallBackToManagerDownload() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentNoManager-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root)
        do {
            _ = try await ManagedRuntimeComponents.prepare(provider: "notproton", paths: paths)
            Issue.record("Missing internal components must fail locally")
        } catch let error as AppFailure {
            #expect(error.localizedDescription.contains("Internal components missing"))
        }
        #expect(!FileStore.fm.fileExists(atPath: paths.cache.path))
    }
    @Test func crossOverBridgeUsesInternalResourcesAndPreservesCoreCache() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentInternalBridge-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let app = root.appendingPathComponent("MacSteamTool.app"), paths = AppPaths(home: root)
        let embedded = app.appendingPathComponent("Contents/Resources/RuntimeBackends/crossover")
        let bridge = "NotProtonRuntime.bundle/Contents/Resources/payload/bridge/steam.exe"
        try FileStore.write(Data("owned-bridge".utf8), to: embedded.appendingPathComponent(bridge))
        let receipt = ManagedRuntimeComponent(provider: "notproton", version: "1.2.3", source: "MacSteamTool maintained source",
            files: try ManagedRuntimeComponents.inventory(embedded), root: URL(fileURLWithPath: "/"))
        try FileStore.json(receipt, to: embedded.appendingPathComponent("component.json"))
        let sentinel = paths.data.appendingPathComponent("Components/notproton/bundled-1.2.3/sentinel")
        try FileStore.write(Data("core".utf8), to: sentinel)
        let component = try ManagedRuntimeComponents.prepareCrossOver(paths: paths, application: app)
        #expect(component.root.lastPathComponent == "crossover-1.2.3")
        #expect(try FileStore.text(component.root.appendingPathComponent(bridge)) == "owned-bridge")
        #expect(try FileStore.text(sentinel) == "core")
        try FileStore.write(Data("tamper".utf8), to: embedded.appendingPathComponent(bridge))
        #expect(throws: AppFailure.self) { try ManagedRuntimeComponents.prepareCrossOver(paths: paths, application: app) }
        #expect(try FileStore.text(component.root.appendingPathComponent(bridge)) == "owned-bridge")
    }
    @Test func bundledCoreNeedsNoDownloadAndDoesNotReplaceBackendCache() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentBundledCoreTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let app = root.appendingPathComponent("MacSteamTool.app"), p = AppPaths(home: root)
        let embedded = app.appendingPathComponent("Contents/Resources/RuntimeComponents/macsteam/0.8.2")
        try FileStore.write(Data("core".utf8), to: embedded.appendingPathComponent("Resources/macsteam.dylib"))
        let receipt = ManagedRuntimeComponent(provider: "macsteam", version: "0.8.2", source: "fixture", files: try ManagedRuntimeComponents.inventory(embedded), root: URL(fileURLWithPath: "/"))
        try FileStore.json(receipt, to: embedded.appendingPathComponent("component.json"))
        let backend = p.data.appendingPathComponent("Components/macsteam/0.8.2/sentinel")
        try FileStore.write(Data("keep-backend".utf8), to: backend)
        let installed = try await ManagedRuntimeComponents.prepare(provider: "macsteam", paths: p, application: app)
        try ManagedRuntimeComponents.validate(installed)
        #expect(installed.root.lastPathComponent == "bundled-0.8.2")
        #expect(try FileStore.text(backend) == "keep-backend")
        try FileStore.write(Data("tampered".utf8), to: installed.resources.appendingPathComponent("macsteam.dylib"))
        let repaired = try ManagedRuntimeComponents.prepareBundled(provider: "macsteam", paths: p, application: app)
        #expect(try FileStore.text(repaired.resources.appendingPathComponent("macsteam.dylib")) == "core")
        try FileStore.write(Data("bad-shipping-core".utf8), to: embedded.appendingPathComponent("Resources/macsteam.dylib"))
        #expect(throws: AppFailure.self) { try ManagedRuntimeComponents.prepareBundled(provider: "macsteam", paths: p, application: app) }
        // Configuring cores must not create a default backend or Steam config.
        _ = try OneClickSetup.seedConfiguration(paths: p, defaultTool: nil, requireIdle: {})
        #expect(!FileStore.fm.fileExists(atPath: p.steam.appendingPathComponent("config/config.vdf").path))
        #expect(!FileStore.fm.fileExists(atPath: FreeRuntime.root(p).path))
    }
    @Test func preservesAllExistingChoices() throws {
        let fresh = try SteamCompatibility.seedDefault(nil, tool: FreeRuntime.toolID)
        #expect(try SteamCompatibility.globalTool(fresh) == FreeRuntime.toolID)
        let paid = try SteamCompatibility.seedDefault(nil, tool: "notproton-crossover-test")
        let perGame = try SteamCompatibility.edit(paid, appID: 123, tool: "notproton-existing")
        #expect(try SteamCompatibility.seedDefault(perGame, tool: FreeRuntime.toolID) == perGame)
        #expect(try SteamCompatibility.mapping(perGame, appID: 123)?.string("name") == "notproton-existing")
        let automatic = Data(String(decoding: perGame, as: UTF8.self).replacingOccurrences(of: "notproton-crossover-test", with: "").utf8)
        #expect(try SteamCompatibility.seedDefault(automatic, tool: FreeRuntime.toolID) == automatic)
        #expect(throws: (any Error).self) { try SteamCompatibility.seedDefault(Data("broken".utf8), tool: FreeRuntime.toolID) }
    }
    @Test func existingConfigUntouchedAndFailedCommitDoesNotWrite() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentSetupTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let p = AppPaths(home: root)
        let manual = Data("HideWhatsNew: yes\n# retain formatting\nCustom: untouched\n".utf8)
        try FileStore.write(manual, to: p.config)
        #expect(try OneClickSetup.seedConfiguration(paths: p, defaultTool: nil, requireIdle: {}) == nil)
        #expect(try FileStore.read(p.config) == manual)
        try FileStore.fm.removeItem(at: p.config)
        #expect(throws: AppFailure.self) {
            try OneClickSetup.seedConfiguration(paths: p, defaultTool: nil, requireIdle: { throw AppFailure("Steam restarted") })
        }
        #expect(!FileStore.fm.fileExists(atPath: p.config.path))
        #expect(try OneClickSetup.seedConfiguration(paths: p, defaultTool: nil, requireIdle: {}) != nil)
        #expect(try MacSteamConfig.parse(FileStore.text(p.config)).apps.isEmpty)
    }
    @Test func detectsCorruptAndUnlistedManagedPayload() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentComponentTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let file = root.appendingPathComponent("Resources/macsteam.dylib")
        try FileStore.write(Data("payload".utf8), to: file)
        let c = ManagedRuntimeComponent(provider: "macsteam", version: "0.8.2", source: "test", files: try ManagedRuntimeComponents.inventory(root), root: root)
        try FileStore.json(c, to: root.appendingPathComponent("component.json"))
        try ManagedRuntimeComponents.validate(c)
        try FileStore.write(Data("extra".utf8), to: root.appendingPathComponent("Resources/component.json"))
        #expect(throws: AppFailure.self) { try ManagedRuntimeComponents.validate(c) }
        try FileStore.fm.removeItem(at: root.appendingPathComponent("Resources/component.json"))
        try FileStore.write(Data("tampered".utf8), to: file)
        #expect(throws: AppFailure.self) { try ManagedRuntimeComponents.validate(c) }
    }
    @Test func stagingInventorySurvivesMoveAndTemporaryPathAliases() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentMovedTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)"), target = root.appendingPathComponent("0.8.2")
        try FileStore.write(Data("binary".utf8), to: stage.appendingPathComponent("Resources/macsteam.dylib"))
        let before = try ManagedRuntimeComponents.inventory(stage)
        #expect(Set(before.keys) == ["Resources/macsteam.dylib"])
        try FileStore.fm.moveItem(at: stage, to: target)
        #expect(try ManagedRuntimeComponents.inventory(target) == before)
    }
    @Test func sharedValveCacheRequiresMatchingHash() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentValveReuseTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let p = AppPaths(home: root), resources = root.appendingPathComponent("resources"), bytes = Data("pinned-package".utf8)
        try FileStore.write(bytes, to: p.cache.appendingPathComponent("ValvePackages/good.zip"))
        try FileStore.write(Data("wrong".utf8), to: p.cache.appendingPathComponent("ValvePackages/bad.zip"))
        try FileStore.write(Data("package test good.zip \(FileStore.hash(bytes))\npackage test bad.zip \(FileStore.hash(bytes))\n".utf8), to: resources.appendingPathComponent("valve-packages.manifest"))
        try FreeRuntime.reuseValvePackages(paths: p, resources: resources)
        #expect(try FileStore.read(p.cache.appendingPathComponent("FreeRuntime/valve/good.zip")) == bytes)
        #expect(!FileStore.fm.fileExists(atPath: p.cache.appendingPathComponent("FreeRuntime/valve/bad.zip").path))
    }
    @Test func runtimeLockRejectsConcurrentInstallAndAllowsRetryAfterRelease() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentRuntimeLockTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let p = AppPaths(home: root), support = FreeRuntime.root(p), archive = root.appendingPathComponent("bad.dmg")
        try FileStore.mkdir(support); try FileStore.write(Data("corrupt".utf8), to: archive)
        let fd = open(support.appendingPathComponent(".installation-lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0); #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        do { try await FreeRuntime.install(paths: p, resources: root, archive: archive); Issue.record("Accepted competing install") }
        catch { #expect(error.localizedDescription.contains("already running")) }
        flock(fd, LOCK_UN); close(fd)
        // The lock file deliberately remains. Only the kernel-held lock counts.
        do { try await FreeRuntime.install(paths: p, resources: root, archive: archive); Issue.record("Accepted corrupt archive") }
        catch { #expect(error.localizedDescription.contains("digest mismatch")) }
    }
    @Test func neverDowngradesNewerInstalledKernel() {
        #expect(OneClickSetup.preserveNewer(installed: "1.2.4", candidate: "1.2.3"))
        #expect(OneClickSetup.preserveNewer(installed: "1.10.0", candidate: "1.2.3"))
        #expect(!OneClickSetup.preserveNewer(installed: "1.2.3", candidate: "1.2.3"))
        #expect(!OneClickSetup.preserveNewer(installed: "—", candidate: "1.2.3"))
    }
    @Test func failedSetupRecordsFailureWithoutTouchingOtherPaths() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentSetupJournalTest-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        var p = AppPaths(home: root); p.steamApp = root.appendingPathComponent("Steam.app")
        let prepared = OneClickSetup.Prepared(paths: p, options: SetupOptions(), awaitingFirstSteamLaunch: true)
        do {
            _ = try await OneClickSetup.install(prepared, application: root.appendingPathComponent("MissingInstaller.app"))
            Issue.record("Missing installer unexpectedly succeeded")
        } catch {
            let journal = try FileStore.decode(SetupJournal.self, at: OneClickSetup.journalURL(p))
            #expect(journal.state == "failed")
            #expect(journal.error != nil)
            #expect(journal.awaitingFirstSteamLaunch)
            #expect(journal.completed.isEmpty)
            #expect(!FileStore.fm.fileExists(atPath: p.steamApp.path))
        }
    }
}
