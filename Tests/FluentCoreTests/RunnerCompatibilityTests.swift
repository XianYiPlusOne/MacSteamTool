import Foundation
import Testing
@testable import FluentCore

@Suite struct RunnerCompatibilityTests {
    @Test func sharedOptionsRespectBackendAndKeepIndependentDXMTSettings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let wine = RunnerCompatibility(wine: true, build: nil, fex: false, paths: paths)
        let cx = RunnerCompatibility(wine: false, build: "26.3.0", fex: false, paths: paths)
        let fex = RunnerCompatibility(wine: false, build: "26.3.0-fex", fex: true, paths: paths)
        #expect(wine.options(for: .automatic).map(\.id) == cx.options(for: .automatic).map(\.id))
        #expect(!fex.renderers.contains(.d3dmetal))
        #expect(!fex.options(for: .automatic).contains { $0.id == "ROSETTA_ADVERTISE_AVX" })
        func option(_ id: String) throws -> CompatibilityOption { try #require(wine.options(for: .dxmt).first { $0.id == id }) }
        try wine.set("dxmt", for: option("CX_GRAPHICS_BACKEND"), requireIdle: {})
        try wine.set("1.72", for: option("dxmt-scale"), requireIdle: {})
        try wine.set("60", for: option("dxmt-fps"), requireIdle: {})
        try wine.set("1", for: option("NOTPROTON_RETINA"), requireIdle: {})
        #expect(try cx.settings() == wine.settings())
        let scale = try option("dxmt-scale"), fps = try option("dxmt-fps")
        #expect(try fps.value(in: wine.settings()) == "60")
        #expect(try scale.value(in: wine.settings()) == "1.72")
        try cx.set("", for: scale, requireIdle: {})
        #expect(try scale.value(in: cx.settings()) == "")
        #expect(try fps.value(in: cx.settings()) == "60")
        #expect(try scale.value(in: wine.settings()) == "1.72")
        try wine.set("dxvk", for: option("CX_GRAPHICS_BACKEND"), requireIdle: {})
        #expect(throws: AppFailure.self) { try wine.set("2.0", for: scale, requireIdle: {}) }
        #expect(try wine.settings()["NOTPROTON_RETINA"] == "1")
    }

    @Test func helperUsesGameSessionBeforeFamilyDefaults() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: home) }
        let paths = AppPaths(home: home), prefix = home.appendingPathComponent("fluent-free/pfx")
        let wine = RunnerCompatibility(wine: true, build: nil, fex: false, paths: paths)
        try FileStore.write(Data("CX_GRAPHICS_BACKEND=dxmt\nMTL_HUD_ENABLED=0\n".utf8), to: paths.notProton.appendingPathComponent("defaults-rosetta"))
        let record = prefix.deletingLastPathComponent().appendingPathComponent("notproton-session.env")
        try FileStore.write(Data("CX_GRAPHICS_BACKEND=dxvk\nMTL_HUD_ENABLED=1\nWINEPREFIX=/wrong\n".utf8), to: record)
        var env = ["WINEPREFIX": prefix.path]
        #expect(throws: AppFailure.self) { try wine.configureTool(runner: home, prefix: prefix, environment: &env) }
        let overlay = home.appendingPathComponent("lib/renderers/dxvk")
        try FileStore.write(Data(), to: overlay.appendingPathComponent("x86_64-windows/d3d11.dll"))
        try wine.configureTool(runner: home, prefix: prefix, environment: &env)
        #expect(env["WINEDLLPATH_PREPEND"] == overlay.path)
        #expect(env["CX_ACTIVE_GRAPHICS_BACKEND"] == "dxvk")
        #expect(env["MTL_HUD_ENABLED"] == "1")
        #expect(env["WINEPREFIX"] == prefix.path)
        try FileStore.write(Data("CX_GRAPHICS_BACKEND=wined3d\n".utf8), to: record)
        try wine.configureTool(runner: home, prefix: prefix, environment: &env)
        #expect(env["WINEDLLPATH_PREPEND"] == nil)
        #expect(env["CX_ACTIVE_GRAPHICS_BACKEND"] == "wined3d")
        try FileStore.write(Data("CX_GRAPHICS_BACKEND=auto\n".utf8), to: record)
        let cx = RunnerCompatibility(wine: false, build: nil, fex: false, paths: paths)
        try cx.configureTool(runner: home, prefix: prefix, environment: &env)
        #expect(env["CX_GRAPHICS_BACKEND"] == nil)
    }
}
