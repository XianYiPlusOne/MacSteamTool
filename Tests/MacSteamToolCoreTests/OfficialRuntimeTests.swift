import Foundation
import Testing
import ZIPFoundation
@testable import MacSteamToolCore

@Suite struct OfficialRuntimeTests {
    func release() -> OfficialRuntimeRelease { .init(provider: "notproton", tag: "v1.2.4", version: "1.2.4", assetName: "NotProton.zip", url: "https://github.com/NotProtonNot/NotProton/releases/download/v1.2.4/NotProton.zip", sha256: String(repeating: "a", count: 64), releaseURL: "https://github.com/NotProtonNot/NotProton/releases/tag/v1.2.4") }
    @Test func releaseTrustBoundary() throws {
        try release().validate()
        for value in ["http://github.com/NotProtonNot/NotProton/releases/download/v1.2.4/NotProton.zip", "https://github.com/other/NotProton/releases/download/v1.2.4/NotProton.zip", release().url + "?token=x"] {
            var bad = release(); bad.url = value; #expect(throws: (any Error).self) { try bad.validate() }
        }
        var bad = release(); bad.sha256 = ""; #expect(throws: (any Error).self) { try bad.validate() }
        bad = release(); bad.version = "1.2.3"; #expect(throws: (any Error).self) { try bad.validate() }
    }
    func zip(_ entries: [(String, Entry.EntryType, String)], root: URL) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString + ".zip"), archive = try Archive(url: file, accessMode: .create)
        for (path, type, contents) in entries {
            let data = Data(contents.utf8)
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { position, count in data.subdata(in: Int(position)..<(Int(position)+count)) }
        }
        return file
    }
    @Test func safeFrameworkLinksAndUnsafeArchives() throws {
        let root = FileStore.fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(root); defer { try? FileStore.fm.removeItem(at: root) }
        let good = try zip([("NotProton.app/Contents/Frameworks/F.framework/Versions/A/F", .file, "fixture"), ("NotProton.app/Contents/Frameworks/F.framework/Versions/Current", .symlink, "A"), ("NotProton.app/Contents/Frameworks/F.framework/F", .symlink, "Versions/Current/F")], root: root)
        let output = root.appendingPathComponent("good"); try FileStore.mkdir(output)
        try OfficialRuntimeUpdates.extractZIP(good, into: output, appName: "NotProton.app")
        #expect(try FileStore.text(output.appendingPathComponent("NotProton.app/Contents/Frameworks/F.framework/F")) == "fixture")
        let bad: [[(String, Entry.EntryType, String)]] = [
            [("../outside", .file, "bad")], [("Other.app/file", .file, "bad")],
            [("NotProton.app/a", .file, "one"), ("NotProton.app/A", .file, "two")],
            [("NotProton.app/Contents/link", .symlink, "../../../outside")],
            [("NotProton.app/Contents/link", .symlink, "target"), ("NotProton.app/Contents/link/child", .file, "bad")],
            [("NotProton.app/Contents/a", .symlink, "b"), ("NotProton.app/Contents/b", .symlink, "a")]
        ]
        for entries in bad {
            let archive = try zip(entries, root: root), destination = root.appendingPathComponent(UUID().uuidString)
            try FileStore.mkdir(destination)
            #expect(throws: (any Error).self) { try OfficialRuntimeUpdates.extractZIP(archive, into: destination, appName: "NotProton.app") }
        }
        #expect(!FileStore.fm.fileExists(atPath: root.appendingPathComponent("outside").path))
    }
}
