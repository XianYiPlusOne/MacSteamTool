import Testing
import Foundation
@testable import FluentCore

@Suite("Free runtime isolation")
final class FreeRuntimeTests {
    private var resources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/FreeRuntime") }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Fluent free ' $ test-\(UUID().uuidString)")
        try FileStore.mkdir(url); return url
    }
    private var config: Data { Data("\"InstallConfigStore\" { \"Software\" { \"Valve\" { \"Steam\" { \"CompatToolMapping\" { \"0\" { \"name\" \"fluent-proton-free\" } } } } } }".utf8) }
    @Test func testSelectedPrefixNeverFallsBackToPaidEnvironment() throws {
        let home = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        let paths = AppPaths(home: home), data = paths.steam.appendingPathComponent("steamapps/compatdata/42")
        try FileStore.mkdir(data.appendingPathComponent("pfx"))
        try FileStore.mkdir(paths.steam.appendingPathComponent("config"))
        let file = paths.steam.appendingPathComponent("config/config.vdf")
        try config.write(to: file)
        #expect(SteamLibrary.prefixes(paths).isEmpty)
        try FileStore.mkdir(FreeRuntime.prefix(in: data))
        #expect(SteamLibrary.prefixes(paths).first?.url.resolvingSymlinksInPath().path == FreeRuntime.prefix(in: data).resolvingSymlinksInPath().path)
        try SteamCompatibility.edit(config, appID: 42, tool: "notproton-paid").write(to: file)
        #expect(SteamLibrary.prefixes(paths).first?.url.resolvingSymlinksInPath().path == data.appendingPathComponent("pfx").resolvingSymlinksInPath().path)
    }
    @Test func testLauncherReportsSeparatePathAndRejectsMaliciousVariableName() async throws {
        let temp = try fixture(); defer { try? FileStore.fm.removeItem(at: temp) }
        let tool = temp.appendingPathComponent("tool"), runtime = temp.appendingPathComponent("runtime")
        try FileStore.mkdir(tool); try FileStore.mkdir(runtime.appendingPathComponent("runner"))
        try FileStore.fm.copyItem(at: resources.appendingPathComponent("run"), to: tool.appendingPathComponent("run"))
        try Data(runtime.path.utf8).write(to: tool.appendingPathComponent("runtime-root"))
        let marker = temp.appendingPathComponent("unexpected")
        try Data("WINE$(touch '\(marker.path)')=yes\n".utf8).write(to: runtime.appendingPathComponent("global.env"))
        var env = FreeRuntime.environment(); env["STEAM_COMPAT_DATA_PATH"] = temp.appendingPathComponent("compatdata/42").path
        let (code, text) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), [tool.appendingPathComponent("run").path, "getcompatpath"], environment: env)
        #expect(code == 0); #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == env["STEAM_COMPAT_DATA_PATH"]! + "/fluent-free")
        #expect(!FileStore.fm.fileExists(atPath: marker.path))
        env["STEAM_COMPAT_DATA_PATH"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (_, repeated) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), [tool.appendingPathComponent("run").path, "getcompatpath"], environment: env)
        #expect(repeated == text)
        let (unready, reason) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), [tool.appendingPathComponent("run").path, "run", "/unused.exe"], environment: env)
        #expect(unready != 0); #expect(reason.contains("needs repair"))
    }
    @Test func testBadArchiveLeavesRegistrationAndInstalledVersionIntact() async throws {
        let home = try fixture(); defer { try? FileStore.fm.removeItem(at: home) }
        let paths = AppPaths(home: home), tool = FreeRuntime.tool(paths)
        try FileStore.mkdir(tool)
        let marker = tool.appendingPathComponent("existing")
        try Data("previous".utf8).write(to: marker)
        let bad = home.appendingPathComponent("bad.dmg"); try Data("corrupt".utf8).write(to: bad)
        do { try await FreeRuntime.install(paths: paths, resources: resources, archive: bad); Issue.record("Corrupt release accepted") }
        catch { #expect(error.localizedDescription.contains("digest mismatch")) }
        #expect(try FileStore.text(marker) == "previous")
        #expect(FileStore.files(FreeRuntime.root(paths).appendingPathComponent("versions")).isEmpty)
        #expect(!FileStore.fm.fileExists(atPath: FreeRuntime.root(paths).appendingPathComponent("install.lock").path))
    }
    @Test func freeOnlyInstallationAndGlobalPreferenceAreSelectable() throws {
        let free = SteamCompatibility.Tool(id: FreeRuntime.toolID, name: "Fluent Wine")
        let paid = SteamCompatibility.Tool(id: "notproton-26.3", name: "CrossOver")
        #expect(try AutomaticCompatibility.preferredTool([free], config: config) == FreeRuntime.toolID)
        #expect(try AutomaticCompatibility.preferredTool([paid, free], config: config) == FreeRuntime.toolID)
        let override = try SteamCompatibility.edit(config, appID: 42, tool: "notproton-26.3")
        #expect(!FreeRuntime.selected(override, appID: 42))
    }
}
