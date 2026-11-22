import Foundation
import CryptoKit
import Testing
@testable import MacSteamToolCore

@Suite struct UpdateTests {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(root); return root
    }
    func signed(_ release: UpdateRelease, key: Curve25519.Signing.PrivateKey) throws -> SignedUpdate {
        let payload = try JSONEncoder().encode(release)
        return SignedUpdate(payload: payload, signature: try key.signature(for: payload))
    }
    @Test func signaturesAndPrivacy() throws {
        let key = Curve25519.Signing.PrivateKey(), release = UpdateRelease(version: "0.2.0", build: 2, url: "https://example.com/app.zip", sha256: String(repeating: "a", count: 64), size: 123)
        let envelope = try signed(release, key: key)
        #expect(try envelope.verified(publicKey: key.publicKey.rawRepresentation) == release)
        #expect(throws: (any Error).self) { try envelope.verified(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) }
        var bad = envelope; bad.payload.append(0)
        #expect(throws: (any Error).self) { try bad.verified(publicKey: key.publicKey.rawRepresentation) }
        let original = "/Users/test/doc ticket appticket=abcd token?token=secret SteamID=76561197960265729 " + String(repeating: "a", count: 64)
        let clean = FeedbackReport.redact(original, home: "/Users/test")
        #expect(!clean.contains("/Users/test")); #expect(!clean.contains("abcd")); #expect(!clean.contains("secret")); #expect(!clean.contains("76561197960265729")); #expect(!clean.contains(String(repeating: "a", count: 64)))
        for sample in ["token=DEMO_SECRET_ONLY", "Authorization: Bearer DEMO_SECRET_ONLY", "\"api_key\":\"DEMO_SECRET_ONLY\"", "password='DEMO_SECRET_ONLY with spaces'", "refresh-token=DEMO_SECRET_ONLY"] {
            #expect(!FeedbackReport.redact(sample).contains("DEMO_SECRET_ONLY"))
        }
    }
    @Test func downloadRoutingNeverMirrorsCredentials() throws {
        let publicURL = URL(string: "https://github.com/a/b/releases/download/v1/app.zip")!
        #expect(DownloadSources.candidates(publicURL, preferred: "https://ghfast.top/").count == 2)
        for url in ["https://github.com/a/b?token=secret", "https://user:password@github.com/a/b", "https://api.steampowered.com/", "http://github.com/a/b"] {
            let u = URL(string: url)!; #expect(DownloadSources.candidates(u, preferred: "https://ghfast.top/") == [u])
        }
        #expect(!DownloadSources.validCDN("host/path")); #expect(!DownloadSources.validCDN("host:443")); #expect(DownloadSources.validCDN("cache.example.com"))
    }
    @Test func providerConfigBackwardCompatibleAndScoped() throws {
        let old = try JSONDecoder().decode(RuntimeFeatures.self, from: Data(#"{"presence":"unchanged","presenceApps":{},"tickets":{}}"#.utf8))
        #expect(old.manifestProvider == nil)
        var config = ManifestProviderConfiguration(); config.mode = .custom
        #expect(throws: (any Error).self) { try config.validate() }
        config.apps = ["480"]; try config.validate()
        for invalid in ["https://u:p@host/{manifest}", "http://example.com/{manifest}", "https://host/{other}/{manifest}", "https://host/{manifest}#secret"] {
            config.url = invalid; #expect(throws: (any Error).self) { try config.validate() }
        }
        config.url = "http://127.0.0.1:3456/{manifest}"; try config.validate()
    }
    func app(_ root: URL, build: Int, legacy: Bool = false) async throws -> URL {
        let app = root.appendingPathComponent(legacy ? "Fluent Steam Mac.app" : "MacSteamTool.app")
        let executable = legacy ? "FluentSteam" : "MacSteamTool"
        try FileStore.mkdir(app.appendingPathComponent("Contents/MacOS"))
        let source = root.appendingPathComponent("main.c")
        try FileStore.write(Data("int main(void){return 0;}\n".utf8), to: source)
        let (compile, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/clang"), ["-arch", "arm64", source.path, "-o", app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path])
        #expect(compile == 0)
        let info = ["CFBundleIdentifier": legacy ? "dev.fluentsteam.mac" : AppUpdates.bundleID, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL", "CFBundleVersion": String(build), "CFBundleShortVersionString": "0.\(build).0"]
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: app.appendingPathComponent("Contents/Info.plist"))
        let (sign, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--deep", "--sign", "-", app.path]); #expect(sign == 0)
        return app
    }
    @Test(arguments: [false, true]) func signedArchiveInstallAndConflict(legacyArchive: Bool) async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let target = try await app(root.appendingPathComponent("installed"), build: 1)
        let source = try await app(root.appendingPathComponent("new"), build: 2, legacy: legacyArchive)
        let archive = root.appendingPathComponent("release.zip")
        let (zip, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", source.path, archive.path]); #expect(zip == 0)
        let bytes = try FileStore.read(archive), key = Curve25519.Signing.PrivateKey()
        let release = UpdateRelease(version: "0.2.0", build: 2, url: "", sha256: FileStore.hash(bytes), size: bytes.count)
        let envelope = try signed(release, key: key)
        let prepared = try await AppUpdates.prepare(envelope, publicKey: key.publicKey.rawRepresentation, archive: archive, staging: root.appendingPathComponent("stage"), currentBuild: 1)
        let sourceHash = try AppUpdates.treeHash(prepared.application), before = try AppUpdates.treeHash(target)
        let conflict = UpdateInstallPlan(source: prepared.application, target: target, expectedSource: sourceHash, expectedTarget: "wrong", parentPID: 0, build: 2)
        await #expect(throws: (any Error).self) { try await AppUpdates.install(conflict) }
        #expect(try AppUpdates.treeHash(target) == before)
        let plan = UpdateInstallPlan(source: prepared.application, target: target, expectedSource: sourceHash, expectedTarget: before, parentPID: 0, build: 2)
        let backup = try await AppUpdates.install(plan)
        #expect(try AppUpdates.treeHash(target) == sourceHash); #expect(try AppUpdates.treeHash(backup) == before)
        await #expect(throws: (any Error).self) { try await AppUpdates.prepare(envelope, publicKey: key.publicKey.rawRepresentation, archive: archive, staging: root, currentBuild: 2) }
        try FileStore.write(Data("corrupt".utf8), to: archive)
        await #expect(throws: (any Error).self) { try await AppUpdates.prepare(envelope, publicKey: key.publicKey.rawRepresentation, archive: archive, staging: root, currentBuild: 1) }
    }
    @Test func traversalAndUnsignedApplicationRejected() async throws {
        let root = try root(); defer { try? FileStore.fm.removeItem(at: root) }
        let zip = root.appendingPathComponent("bad.zip")
        try ArchiveIO.export([ImportFile(name: "../escape", data: Data([1]))], to: zip)
        let key = Curve25519.Signing.PrivateKey(), bytes = try FileStore.read(zip)
        let release = UpdateRelease(version: "0.2.0", build: 2, url: "", sha256: FileStore.hash(bytes), size: bytes.count)
        let envelope = try signed(release, key: key)
        await #expect(throws: (any Error).self) { try await AppUpdates.prepare(envelope, publicKey: key.publicKey.rawRepresentation, archive: zip, staging: root.appendingPathComponent("stage"), currentBuild: 1) }
        #expect(!FileStore.fm.fileExists(atPath: root.appendingPathComponent("escape").path))
        let app = try await app(root.appendingPathComponent("unsigned"), build: 2)
        try FileStore.write(Data([0]), to: app.appendingPathComponent("Contents/MacOS/MacSteamTool"))
        await #expect(throws: (any Error).self) { try await AppUpdates.validate(app) }
    }
}

@Suite struct InventoryTests {
    @Test func itemDefinitionsPreserveFieldsAndRejectDuplicates() throws {
        let parsed = try OfflineInventory.parse(Data(#"[{"itemdefid":10,"name":"Test","tradable":false},{"itemdefid":"20","name":"Two","tags":["a","b"]}]"#.utf8))
        #expect(parsed.quantities == ["10": 1, "20": 1]); #expect(parsed.items["10"]?["name"] == "Test")
        #expect(parsed.items["20"]?["tags"] == "[\"a\",\"b\"]")
        let roundtrip = try OfflineInventory.parse(JSONEncoder().encode(parsed.items)); #expect(roundtrip.items == parsed.items)
        #expect(throws: (any Error).self) { try OfflineInventory.parse(Data(#"[{"itemdefid":1},{"itemdefid":1}]"#.utf8)) }
        #expect(throws: (any Error).self) { try OfflineInventory.parse(Data(#"{"1":{"itemdefid":2}}"#.utf8)) }
        #expect(throws: (any Error).self) { try OfflineInventory.parse(Data(#"[{"itemdefid":"../escape"}]"#.utf8)) }
    }
}
