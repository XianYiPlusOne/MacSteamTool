import Foundation
import Testing
@testable import FluentCore

struct NativeIntegrationTests {
    struct Fixture {
        let root: URL
        var paths: AppPaths
        let app: URL
        init() throws {
            root = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentAutoIntegration-\(UUID().uuidString)")
            paths = AppPaths(home: root); paths.steamApp = root.appendingPathComponent("Steam.app")
            app = root.appendingPathComponent("Fluent.app")
            var inserts: [String] = []
            for (provider, version) in ManagedRuntimeComponents.versions {
                let component = app.appendingPathComponent("Contents/Resources/RuntimeComponents/\(provider)/\(version)")
                let prefix = provider == "macsteam" ? "Resources" : "NotProtonRuntime.bundle/Contents/Resources/payload"
                let resources = component.appendingPathComponent(prefix)
                let support = provider == "macsteam" ? paths.macSteam : paths.notProton
                let library = paths.steamApp.appendingPathComponent("Contents/MacOS/\(provider).dylib")
                try FileStore.write(Data(provider.utf8), to: resources.appendingPathComponent("\(provider).dylib"))
                try FileStore.write(Data(provider.utf8), to: library); inserts.append(library.path)
                try FileStore.write(Data((version + "\n").utf8), to: support.appendingPathComponent("dylib.version"))
                try FileStore.write(Data("profile".utf8), to: resources.appendingPathComponent("signatures/macos.arm64/123.json"))
                try FileStore.write(Data("profile".utf8), to: support.appendingPathComponent("signatures/macos.arm64/123.json"))
                if provider == "notproton" {
                    for name in ["overlay-shim.dylib", "iconmaker", "appinfo"] {
                        try FileStore.write(Data(name.utf8), to: resources.appendingPathComponent(name))
                        try FileStore.write(Data(name.utf8), to: support.appendingPathComponent(name))
                    }
                    try FileStore.write(Data(provider.utf8), to: app.appendingPathComponent("Contents/Resources/Helpers/NotProtonRepair/notproton.dylib"))
                    try FileStore.write(Data(app.appendingPathComponent("Contents/Helpers/NotProton/FluentNotProton").path.utf8), to: support.appendingPathComponent("app-executable"))
                }
                let receipt = ManagedRuntimeComponent(provider: provider, version: version, source: "test", files: try ManagedRuntimeComponents.inventory(component), root: component)
                try FileStore.json(receipt, to: component.appendingPathComponent("component.json"))
            }
            for (name, folder) in [("cloud_redirect.dylib", "Cloud"), ("fluent_manifest.dylib", "Manifest")] {
                let library = paths.steamApp.appendingPathComponent("Contents/MacOS/\(name)")
                try FileStore.write(Data(name.utf8), to: library); inserts.append(library.path)
                try FileStore.write(Data(name.utf8), to: app.appendingPathComponent("Contents/Helpers/\(folder)/\(name)"))
            }
            let env = ["DYLD_INSERT_LIBRARIES": inserts.joined(separator: ":"), "SDL_JOYSTICK_BLACKLIST_DEVICES": "0x05ac/0x0004", "FLUENT_CLOUD_ROOT": paths.data.path, "FLUENT_CLOUD_STEAM": paths.steam.path, "FLUENT_PINS_CONFIG": paths.config.path, "FLUENT_PINS_CACHE": paths.steam.appendingPathComponent("depotcache").path, "FLUENT_PINS_STATUS": paths.data.appendingPathComponent("manifest-pins.log").path]
            let plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "LSEnvironment": env]
            try FileStore.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: paths.steamApp.appendingPathComponent("Contents/Info.plist"))
            try FileStore.write(Data(MacSteamConfig().serialized().utf8), to: paths.config)
        }
    }
    @Test func detectsLostHooksAndCorruptSupportButPreservesNewerCores() throws {
        let f = try Fixture(); defer { try? FileStore.fm.removeItem(at: f.root) }
        #expect(try !NativeIntegration.needsPreparation(paths: f.paths, application: f.app))
        let library = f.paths.steamApp.appendingPathComponent("Contents/MacOS/notproton.dylib")
        try FileStore.write(Data("new-core".utf8), to: library)
        #expect(try NativeIntegration.needsPreparation(paths: f.paths, application: f.app))
        try FileStore.write(Data("1.2.4\n".utf8), to: f.paths.notProton.appendingPathComponent("dylib.version"))
        #expect(try !NativeIntegration.needsPreparation(paths: f.paths, application: f.app))
        try FileStore.fm.removeItem(at: library)
        #expect(throws: AppFailure.self) { try NativeIntegration.needsPreparation(paths: f.paths, application: f.app) }
    }
    @Test func movingAppAndSteamUpdatingTriggerPreparationWithoutWatchingGameData() throws {
        let f = try Fixture(); defer { try? FileStore.fm.removeItem(at: f.root) }
        try FileStore.write(Data("# user changes\n".utf8), to: f.paths.config)
        #expect(try !NativeIntegration.needsPreparation(paths: f.paths, application: f.app))
        let record = f.paths.notProton.appendingPathComponent("app-executable")
        let before = try FileStore.read(record)
        try FileStore.write(Data("/OldApp/FluentNotProton".utf8), to: record)
        #expect(try NativeIntegration.needsPreparation(paths: f.paths, application: f.app))
        try FileStore.write(before, to: record)
        try FileStore.fm.removeItem(at: f.paths.steamApp.appendingPathComponent("Contents/MacOS/cloud_redirect.dylib"))
        #expect(try NativeIntegration.needsPreparation(paths: f.paths, application: f.app))
    }
    @Test func existingCrossOverSelectionMatchesSourceBuildAndSupportsLegacyToolName() throws {
        let f = try Fixture(); defer { try? FileStore.fm.removeItem(at: f.root) }
        let source = f.root.appendingPathComponent("CrossOver.app")
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "27.0.0.40921"], format: .xml, options: 0), to: source.appendingPathComponent("Contents/Info.plist"))
        let registration = "\"compatibilitytools\" { \"compat_tools\" { \"notproton\" { \"from_oslist\" \"windows\" \"to_oslist\" \"macos\" } } }"
        try FileStore.write(Data(registration.utf8), to: f.paths.steam.appendingPathComponent("compatibilitytools.d/notproton/compatibilitytool.vdf"))
        let runner = f.paths.notProton.appendingPathComponent("runners/crossover-27.0.0.40921/CrossOver/bin/wine")
        try FileStore.write(Data("fixture".utf8), to: runner)
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let list = f.paths.notProton.appendingPathComponent("tools")
        try FileStore.write(Data("notproton\t27.0.0.40921\trosetta\tCrossOver\n".utf8), to: list)
        #expect(try TranslationRuntime.registeredCrossOverTool(paths: f.paths, source: source) == "notproton")
        try FileStore.write(Data("notproton\t27.0.0.41073\trosetta\tDifferent CrossOver\n".utf8), to: list)
        #expect(try TranslationRuntime.registeredCrossOverTool(paths: f.paths, source: source) == nil)
    }
    @Test func choosingBackendChangesDefaultOnlyAndRequiresSteamExit() throws {
        let f = try Fixture(); defer { try? FileStore.fm.removeItem(at: f.root) }
        let tool = f.paths.steam.appendingPathComponent("compatibilitytools.d/fluent/compatibilitytool.vdf")
        try FileStore.write(Data("\"compatibilitytools\" { \"compat_tools\" { \"fluent-proton-free\" { \"display_name\" \"Wine\" \"from_oslist\" \"windows\" \"to_oslist\" \"macos\" } } }".utf8), to: tool)
        let file = f.paths.steam.appendingPathComponent("config/config.vdf")
        let original = try SteamCompatibility.edit(SteamCompatibility.seedDefault(nil, tool: "notproton-existing"), appID: 123, tool: "notproton-game")
        try FileStore.write(original, to: file)
        #expect(throws: AppFailure.self) { try SteamCompatibility.chooseDefault(paths: f.paths, tool: FreeRuntime.toolID, requireIdle: { throw AppFailure("Steam restarted") }) }
        #expect(try FileStore.read(file) == original)
        try SteamCompatibility.chooseDefault(paths: f.paths, tool: FreeRuntime.toolID, requireIdle: {})
        let changed = try FileStore.read(file)
        #expect(try SteamCompatibility.globalTool(changed) == FreeRuntime.toolID)
        #expect(try SteamCompatibility.mapping(changed, appID: 123)?.string("name") == "notproton-game")
    }
}
