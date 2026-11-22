import Foundation

extension InstallerSelfTest {
    /// Builds inert Mach-O fixtures; all installs and restores stay in a temporary tree.
    static func architectures() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "InstallerArchitectures-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw StepFailure(step: "Test", detail: message) }
            print("PASS: \(message)")
        }
        func command(_ executable: String, _ arguments: [String]) throws {
            // Some Apple silicon CLT installations contain no Intel compiler tools.
            // Run fixture generation natively even when testing the Intel helper.
            let result = try Shell.run("/usr/bin/arch", [InstallerArchitecture.appleSilicon ? "-arm64" : "-x86_64", executable] + arguments)
            guard result.succeeded else { throw StepFailure(step: "Test", detail: result.stderr) }
        }
        let source = root.appending(path: "fixture.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        for arch in InstallerArchitecture.supported.sorted() {
            try command("/usr/bin/xcrun", ["clang", "-arch", arch, source.path, "-o", root.appending(path: arch).path])
            try command("/usr/bin/xcrun", ["clang", "-arch", arch, "-dynamiclib", source.path, "-o", root.appending(path: "\(arch).dylib").path])
        }
        let universal = root.appending(path: "universal.dylib")
        try command("/usr/bin/lipo", ["-create", root.appending(path: "arm64.dylib").path, root.appending(path: "x86_64.dylib").path, "-output", universal.path])
        for arch in InstallerArchitecture.supported.sorted() {
            let bundle = root.appending(path: "fixture-\(arch).app")
            let executable = bundle.appending(path: "Contents/MacOS/steam_osx")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: root.appending(path: arch), to: executable)
            let info: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appending(path: "Contents/Info.plist"))
            let initial = try InstallSnapshot.digest(bundle)
            let library = root.appending(path: "\(arch).dylib")
            try InstallerArchitecture.validateLibrary(universal, steamExecutable: executable)
            var request = InstallRequest(companion: "", steamApp: bundle.path,
                steamData: root.appending(path: "steam-data-\(arch)").path,
                notProton: root.appending(path: "np-\(arch)").path,
                data: root.appending(path: "data-\(arch)").path,
                kernel: "cloud_redirect.dylib", source: library.path)
            let backup = try InstallSession.kernel(request, requireIdle: {}, register: { _ in }, progress: { _ in })
            try check(InstallerArchitecture.slices(of: bundle.appending(path: "Contents/MacOS/cloud_redirect.dylib")) == [arch], "\(arch) native-only kernel installs and signs")
            request.backup = backup
            _ = try InstallSession.restoreKernel(request, requireIdle: {}, register: { _ in })
            try check(try InstallSnapshot.digest(bundle) == initial, "\(arch) backup restores exact original bundle")
            request.source = root.appending(path: arch == "arm64" ? "x86_64.dylib" : "arm64.dylib").path
            var refused = false
            do { _ = try InstallSession.kernel(request, requireIdle: {}, register: { _ in }, progress: { _ in }) }
            catch { refused = true }
            let unchanged = try InstallSnapshot.digest(bundle) == initial
            try check(refused && unchanged, "\(arch) rejects wrong-architecture library before mutation")
        }
        let kept = Set(SupportedRunners.all.flatMap { $0.tools.map(\.name) } + [SupportedRunners.legacyToolName])
        let intel = SupportedRunners.tools(for: SupportedRunners.all, fexAvailable: true, keeping: kept, appleSilicon: false)
        try check(!intel.isEmpty && intel.allSatisfy { $0.tool.flavor != .fex }, "Intel never registers FEX, including retained entries")
        let arm = SupportedRunners.tools(for: SupportedRunners.all, fexAvailable: true, appleSilicon: true)
        try check(arm.contains { $0.tool.flavor == .fex }, "Apple silicon retains FEX registration")

        let payloadRoot = root.appending(path: "payload")
        try fm.createDirectory(at: payloadRoot.appending(path: "fonts"), withIntermediateDirectories: true)
        for name in ["notproton.dylib", "overlay-shim.dylib", "iconmaker", "appinfo", "run", "fonts/test.ttf"] {
            try Data("fixture".utf8).write(to: payloadRoot.appending(path: name))
        }
        try Data("1".utf8).write(to: payloadRoot.appending(path: "build-time"))
        for arch in InstallerArchitecture.supported {
            let directory = payloadRoot.appending(path: "signatures/macos.\(arch)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appending(path: "123.json"))
        }
        let payload = try InstallPayload.locate(root: payloadRoot)
        let files = DeploymentContent.files(payload: payload, bridgePayload: .init(sources: []), app: root,
            bridge: root, signatures: root.appending(path: "deployed-signatures"), fonts: root,
            overlayShim: root, iconmaker: root, appinfo: root, compatTools: root, tools: [], runners: root)
        let profiles = files.filter { $0.name.hasPrefix("signatures/") }
        try check(profiles.count == 2 && Set(profiles.map(\.destination)).count == 2,
                  "ARM and Intel profiles with the same build number deploy to separate directories")
    }
}
