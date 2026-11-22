import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct RemoteLuaFallbackTests {
    @Test func linkFailureRetriesUnderlyingRepository() async throws {
        var attempts: [Bool] = []
        let files = try await RemoteLuaPackage.fetch(preferences: Preferences()) { template, linked in
            #expect(template == RemoteLuaPackage.defaultTemplate)
            attempts.append(linked)
            if linked { throw AppFailure("Link service offline") }
            return [ImportFile(name: "480.lua", data: Data("addappid(480)".utf8))]
        }
        #expect(attempts == [true, false]); #expect(files.count == 1)
    }
    @Test func customSourceIsNotSilentlyReplaced() async throws {
        var preferences = Preferences(); preferences.remotePackageMode = "direct"
        preferences.remotePackageURL = "https://example.com/{app}.zip"
        var calls = 0
        await #expect(throws: (any Error).self) {
            try await RemoteLuaPackage.fetch(preferences: preferences) { template, linked in
                calls += 1; #expect(template == preferences.remotePackageURL); #expect(!linked)
                throw AppFailure("Not found")
            }
        }
        #expect(calls == 1)
    }
    @Test func cancellationNeverContinuesToAnotherSource() async throws {
        var calls = 0
        await #expect(throws: CancellationError.self) {
            try await RemoteLuaPackage.fetch(preferences: Preferences()) { _, _ in
                calls += 1; throw CancellationError()
            }
        }
        #expect(calls == 1)
    }
}
