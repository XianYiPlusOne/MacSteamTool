import Foundation
import Testing
@testable import FluentCore

struct CloudOnlineTests {
    private var dav: [String: String] { ["url": "https://dav.example.test/saves", "username": "fixture", "password": "fixture-only"] }
    @Test func credentialsAreTypedAndExplicitlyAuthenticated() throws {
        var fields = dav; fields["auth"] = "digest"; fields["allow_insecure_http"] = "false"; fields["timeout_sec"] = "45"
        let values = try CloudOnline.credentialValues(fields, provider: .webdav)
        #expect(values["auth"] as? String == "digest")
        #expect(values["allow_insecure_http"] as? Bool == false)
        #expect(values["timeout_sec"] as? Int == 45)
    }
    @Test func plaintextRequiresExplicitConsentAndURLCannotContainSecrets() throws {
        var fields = dav; fields["url"] = "http://127.0.0.1:8234/dav"
        #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .webdav) }
        fields["allow_insecure_http"] = "true"
        #expect(try CloudOnline.credentialValues(fields, provider: .webdav)["allow_insecure_http"] as? Bool == true)
        for bad in ["https://user:password@dav.example.test/", "https://dav.example.test/?token=secret", "file:///tmp", "https://dav.example.test/#fragment"] {
            fields["url"] = bad
            #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .webdav) }
        }
    }
    @Test func invalidCredentialsAndTraversalAreRejected() throws {
        for prefix in ["../save", "game/../other", "game\\other", "%2e%2e", "save\n"] {
            var fields = dav; fields["key_prefix"] = prefix
            #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .webdav) }
        }
        for auth in ["unsupported", "bearer"] {
            var fields = dav; fields["auth"] = auth
            #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .webdav) }
        }
        var fields = dav; fields["password"] = ""
        #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .webdav) }
        fields["auth"] = "none"
        #expect(try CloudOnline.credentialValues(fields, provider: .webdav)["auth"] as? String == "none")
    }
    @Test func bearerAndOAuthTokensAreValidatedWithoutEchoingSecrets() throws {
        var fields = dav; fields["auth"] = "bearer"; fields["bearer_token"] = "fixture-token"
        #expect(try CloudOnline.credentialValues(fields, provider: .webdav)["auth"] as? String == "bearer")
        fields["bearer_token"] = "fixture\r\nHeader: injected"
        #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .webdav) }
        #expect(throws: (any Error).self) { try CloudOnline.credentialValues([:], provider: .onedrive) }
        let oauth = try CloudOnline.credentialValues(["refresh_token": "fixture-only", "expires_at": "1800000000"], provider: .gdrive)
        #expect(oauth["expires_at"] as? Int64 == 1_800_000_000)
    }
    @Test func s3EndpointAndR2AccountValidation() throws {
        var fields = ["access_key_id": "fixture", "secret_access_key": "fixture-only", "bucket": "saves"]
        #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .s3) }
        fields["endpoint"] = "https://s3.example.test"
        #expect(try CloudOnline.credentialValues(fields, provider: .s3)["bucket"] as? String == "saves")
        fields["endpoint"] = "https://s3.example.test/path-is-not-supported"
        #expect(throws: (any Error).self) { try CloudOnline.credentialValues(fields, provider: .s3) }
        fields["endpoint"] = ""; fields["account_id"] = String(repeating: "a", count: 32)
        #expect(try CloudOnline.credentialValues(fields, provider: .r2)["account_id"] as? String == fields["account_id"])
    }
    @Test func accountConversionAndRemoteInventoryDecode() throws {
        #expect(try CloudOnline.accountID("12345") == "12345")
        #expect(try CloudOnline.accountID("76561197960278073") == "12345")
        for invalid in ["0", "-1", "1/../2", "4294967295", "99999999999999999999", "+12"] {
            #expect(throws: (any Error).self) { try CloudOnline.accountID(invalid) }
        }
        let result = try CloudOnline.decodeLast(CloudRemoteInventory.self, from: #"{"success":true,"apps":[{"app_id":"900001","file_count":2,"total_size":4096}]}"#)
        #expect(result.apps.first?.appID == "900001")
        #expect(result.apps.first?.totalSize == 4096)
    }
    @Test func probeMustVerifyEveryStageIncludingCleanup() throws {
        func report(_ cleaned: Bool) throws -> CloudConnectionTest {
            try CloudOnline.decodeLast(CloudConnectionTest.self, from: "{\"success\":true,\"uploaded\":true,\"downloaded\":true,\"verified\":true,\"cleaned\":\(cleaned),\"bytes\":4096,\"sha256\":\"\(String(repeating: "a", count: 64))\"}")
        }
        #expect(try report(true).fullyVerified)
        #expect(try !report(false).fullyVerified)
    }
    @Test func credentialSaveHonorsRegistryWithoutActivatingConfiguration() throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent("CloudOnline-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: root) }
        let paths = AppPaths(home: root, data: root.appendingPathComponent("Data"))
        let target = paths.data.appendingPathComponent("private/custom-dav.json")
        let config = paths.data.appendingPathComponent("CloudRedirect/config.json")
        let original = try JSONSerialization.data(withJSONObject: ["provider": "folder", "enabled": false, "token_paths": ["webdav": target.path]])
        try FileStore.write(original, to: config)
        try CloudEngine.saveCredentials(dav, provider: .webdav, paths: paths)
        #expect(try FileStore.read(config) == original)
        #expect(try CloudEngine.effectiveCredentialsURL(.webdav, paths: paths) == target)
        let mode = try FileStore.fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        var invalid = dav; invalid["url"] = "invalid"
        let previous = try FileStore.read(target)
        #expect(throws: (any Error).self) { try CloudEngine.saveCredentials(invalid, provider: .webdav, paths: paths) }
        #expect(try FileStore.read(target) == previous)
    }
}
