import Foundation
import Testing
@testable import MacSteamToolCore

struct LocalWineTests {
    @Test func invalidExecutableCannotRegisterOrSelectAWineTool() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home), wine = home.appendingPathComponent("bin/wine")
        try FileStore.write(Data("#!/bin/sh\necho invalid\n".utf8), to: wine)
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        await #expect(throws: AppFailure.self) { try await LocalWine.register(wine, paths: paths, home: home, requireIdle: {}) }
        #expect(LocalWine.registered(paths) == nil)
        #expect(try SteamCompatibility.tools(paths: paths).isEmpty)
    }

    @Test func discoveryRecognizesWineBundlesAndSkipsBrokenAndCrossOverLinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin"), app = home.appendingPathComponent("Wine Stable.app")
        let standalone = app.appendingPathComponent("Contents/Resources/wine/bin/wine64")
        let crossOver = home.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        try FileStore.write(Data(), to: crossOver)
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crossOver.path)
        try FileStore.mkdir(bin)
        let link = bin.appendingPathComponent("wine")
        try FileStore.fm.createSymbolicLink(at: link, withDestinationURL: crossOver)
        try FileStore.write(Data(), to: standalone)
        #expect(LocalWine.detect(applications: [app], binaries: [bin]) == nil)
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standalone.path)
        #expect(LocalWine.detect(applications: [app], binaries: [bin]) == standalone)
        try FileStore.fm.removeItem(at: link)
        try FileStore.fm.createSymbolicLink(at: link, withDestinationURL: standalone)
        #expect(LocalWine.detect(applications: [], binaries: [bin]) == link)
        try FileStore.fm.removeItem(at: standalone)
        #expect(LocalWine.detect(applications: [app], binaries: [bin]) == nil)
    }
}
