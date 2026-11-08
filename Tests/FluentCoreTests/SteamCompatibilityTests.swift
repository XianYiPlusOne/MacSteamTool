import Foundation
import Testing
@testable import FluentCore

struct SteamCompatibilityTests {
    let fixture = Data(#"""
    "InstallConfigStore" { "Software" { "Valve" { "Steam" {
      "Unrelated" "keep\\path"
      "CompatToolMapping" {
        "0" { "name" "global-tool" "priority" "75" }
        "481" { "name" "other-tool" "config" "custom" "priority" "250" }
      }
    } } } }
    "OtherRoot" { "name" "retained" }
    """#.utf8)
    @Test func appOverridePreservesOtherGamesAndGlobalDefaults() throws {
        let before = try VDF.parse(String(decoding: fixture, as: UTF8.self))
        let bytes = try SteamCompatibility.edit(fixture, appID: 480, tool: "notproton-26.3")
        let mapping = try #require(try SteamCompatibility.mapping(bytes, appID: 480))
        #expect(mapping.string("name") == "notproton-26.3"); #expect(mapping.string("priority") == "250")
        #expect(try SteamCompatibility.mapping(bytes, appID: 481) == SteamCompatibility.mapping(fixture, appID: 481))
        let cleared = try SteamCompatibility.edit(bytes, appID: 480, tool: nil)
        #expect(try VDF.parse(String(decoding: cleared, as: UTF8.self)) == before)
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("CompatRestore-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let target = root.appendingPathComponent("config.vdf"), tx = FileTransaction(backupRoot: root.appendingPathComponent("backups"))
        try FileStore.write(fixture, to: target)
        let backup = try tx.apply([(target, bytes)], reason: "480 fixture", expectations: [target: FileStore.hash(fixture)])
        try tx.restore(backup, allowedRoots: [root], expectations: [target: FileStore.hash(bytes)])
        #expect(try FileStore.read(target) == fixture)
    }
    @Test func ambiguousConfigurationAndInvalidIDsRefuseEdits() throws {
        #expect(throws: (any Error).self) { try SteamCompatibility.edit(fixture, appID: 0, tool: "tool") }
        #expect(throws: (any Error).self) { try SteamCompatibility.edit(fixture, appID: 480, tool: "../tool") }
        let duplicate = Data(#"""
        "InstallConfigStore" { "Software" { "Valve" { "Steam" { "CompatToolMapping" {
          "480" { "name" "first" } "480" { "name" "second" }
        } } } } }
        """#.utf8)
        #expect(throws: (any Error).self) { try SteamCompatibility.edit(duplicate, appID: 480, tool: nil) }
        #expect(throws: (any Error).self) { try SteamCompatibility.edit(Data("\"OtherRoot\" {}".utf8), appID: 480, tool: "tool") }
    }
}
