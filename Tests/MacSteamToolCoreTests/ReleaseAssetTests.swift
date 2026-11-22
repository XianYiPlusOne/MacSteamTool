import Foundation
import Testing
@testable import MacSteamToolCore

struct ReleaseAssetTests {
    let repository = "example/runtime"
    let tag = "v1.0", name = "Runtime.zip"
    let hash = String(repeating: "a", count: 64)
    var path: String { "/\(repository)/releases/download/\(tag)/\(name)" }

    @Test func jsonBindsTagFilenameSourceAndDigest() throws {
        let asset = ["name": name, "browser_download_url": "https://github.com" + path, "digest": "sha256:" + hash]
        func read(_ assets: [[String: String]], requestedTag: String? = nil) throws -> ReleaseAsset {
            let bytes = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "body": "Release notes", "assets": assets])
            return try ReleaseAssets.parseJSON(bytes, repository: repository, requestedTag: requestedTag) { _ in name }
        }
        #expect(try read([asset], requestedTag: tag).sha256 == hash)
        #expect(try read([asset]).notes == "Release notes")
        #expect(throws: (any Error).self) { try read([asset, asset]) }
        #expect(throws: (any Error).self) { try read([asset], requestedTag: "v2.0") }
        var wrong = asset; wrong["browser_download_url"] = "https://example.invalid" + path
        #expect(throws: (any Error).self) { try read([wrong]) }
        wrong = asset; wrong["digest"] = ""
        #expect(throws: (any Error).self) { try read([wrong]) }
    }

    @Test func expandedAssetsBindDigestToNamedFileAndPreserveNotes() throws {
        let page = Data("<html><body><div class='markdown-body'><h2>Changes</h2><p>Updated <strong>reader</strong>.</p></div></body></html>".utf8)
        func parse(_ label: String, _ href: String) throws -> ReleaseAsset {
            let html = "<html><body><a href='\(href)'>Download</a><clipboard-copy aria-label='Copy to clipboard digest for \(label)' value='sha256:\(hash)'></clipboard-copy></body></html>"
            return try ReleaseAssets.parseHTML(Data(html.utf8), page: page, repository: repository, tag: tag, name: name)
        }
        let resolved = try parse(name, path)
        #expect(resolved.sha256 == hash)
        #expect(resolved.notes?.contains("## Changes") == true)
        #expect(resolved.notes?.contains("**reader**") == true)
        #expect(throws: (any Error).self) { try parse("Other.zip", path) }
        #expect(throws: (any Error).self) { try parse(name, "/other") }
    }

    @Test func verifiedPackageRetriesAndCommitsReceiptTogetherWithPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("source.zip")
        let bytes = Data("offline fixture".utf8)
        try ArchiveIO.export([ImportFile(name: "notes.txt", data: bytes)], to: fixture)
        let digest = FileStore.hash(try FileStore.read(fixture))
        let asset = try ReleaseAsset(repository: repository, tag: tag, name: name,
            url: "https://github.com" + path, digest: "sha256:" + digest)
        let destination = root.appendingPathComponent("cache/package")
        func attempt(succeed: Bool) async throws -> [URL] {
            var requests = [URL]()
            try await ToolPackage.store(asset, provider: "fixture", version: tag, to: destination, mirror: DownloadSources.mirrors[1]) { url, output in
                requests.append(url)
                let temp = root.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                if succeed && requests.count == 2 { try FileManager.default.copyItem(at: fixture, to: temp) }
                else { try Data("wrong hash".utf8).write(to: temp) }
                try ReleaseAssets.storeVerified(temp, sha256: digest, to: output)
            }
            return requests
        }
        await #expect(throws: (any Error).self) { try await attempt(succeed: false) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).isEmpty)
        let requests = try await attempt(succeed: true)
        #expect(requests == DownloadSources.candidates(asset.url, preferred: DownloadSources.mirrors[1]))
        let receipt = try ToolPackage.load(destination, provider: "fixture")
        #expect(receipt.archiveSHA256 == digest)
        #expect(try FileStore.read(receipt.file(ending: "notes.txt", in: destination)) == bytes)
        await #expect(throws: (any Error).self) { try await attempt(succeed: true) }
    }
}
