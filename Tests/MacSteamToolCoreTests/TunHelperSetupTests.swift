import Foundation
import Testing
@testable import MacSteamToolCore

@Suite struct TunHelperSetupTests {
    @Test func quotedPathsCannotBecomeCommands() async throws {
        let path = "/tmp/网卡 ' $HOME $(printf injected) `uname` \\\nfile"
        let (code, output) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "/usr/bin/printf %s " + TunHelperSetup.shellQuote(path)])
        #expect(code == 0); #expect(output == path)
        #expect(throws: (any Error).self) {
            try TunHelperSetup.installScript(helper: URL(fileURLWithPath: path), plist: URL(fileURLWithPath: "/tmp/a"), helperHash: "$(id)", plistHash: String(repeating: "a", count: 64))
        }
    }
    @Test func authorizationScriptCompilesWithoutExecutingIt() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("FluentTunCompile-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: output) }
        let command = try TunHelperSetup.installScript(helper: URL(fileURLWithPath: "/tmp/MacSteamTool's 测试.app/helper"), plist: URL(fileURLWithPath: "/tmp/MacSteamTool's 测试.app/helper.plist"), helperHash: String(repeating: "a", count: 64), plistHash: String(repeating: "b", count: 64))
        let (code, detail) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osacompile"), ["-o", output.path, "-e", TunHelperSetup.appleScript(command)])
        #expect(code == 0, "\(detail)")
    }
    @Test func failedServiceLoadRestoresOldFilesAndReturnsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluentTunRollback-\(UUID().uuidString)")
        try FileStore.mkdir(root); defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("source helper's name")
        let plist = root.appendingPathComponent("source.plist")
        try FileStore.write(Data("#!/bin/sh\necho 'OK utun1'\n".utf8), to: helper)
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: ["Label": TunHelperSetup.service], format: .xml, options: 0), to: plist)
        let installedHelper = root.appendingPathComponent("Library/PrivilegedHelperTools/connecttool-tun-daemon")
        let installedPlist = root.appendingPathComponent("Library/LaunchDaemons/com.connecttool.tunhelper.plist")
        try FileStore.write(Data("old helper".utf8), to: installedHelper)
        try FileStore.write(Data("old plist".utf8), to: installedPlist)
        let launchctl = root.appendingPathComponent("fake-launchctl")
        try FileStore.write(Data("#!/bin/sh\ncase \"$1\" in print) exit 1;; bootstrap) echo 'bootstrap failed' >&2; exit 9;; *) exit 0;; esac\n".utf8), to: launchctl)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launchctl.path)
        // Run the production transaction in an unprivileged temporary directory.
        // Only privilege ownership, signature verification and launchctl are adapted.
        let command = try TunHelperSetup.installScript(helper: helper, plist: plist,
            helperHash: FileStore.hash(FileStore.read(helper)), plistHash: FileStore.hash(FileStore.read(plist)))
            .replacingOccurrences(of: "/Library/", with: root.path + "/Library/")
            .replacingOccurrences(of: "/usr/bin/install -o root -g wheel", with: "/usr/bin/install")
            .replacingOccurrences(of: "/usr/bin/codesign --verify --strict", with: "/usr/bin/true")
            .replacingOccurrences(of: "/bin/launchctl", with: TunHelperSetup.shellQuote(launchctl.path))
        let (code, output) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", command])
        #expect(code == 9, "\(output)")
        #expect(try FileStore.text(installedHelper) == "old helper")
        #expect(try FileStore.text(installedPlist) == "old plist")
        #expect(try FileManager.default.contentsOfDirectory(atPath: installedHelper.deletingLastPathComponent().path) == ["connecttool-tun-daemon"])
    }
}
