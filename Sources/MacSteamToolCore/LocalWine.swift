import Foundation
import Darwin

/// A Steam compatibility tool that invokes the user's Wine installation in place.
public enum LocalWine {
    public static let toolID = "macsteamtool-local-wine"
    static let prefixDirectory = "macsteamtool-local-wine"

    public static func usable(_ executable: URL) -> Bool {
        let resolved = executable.resolvingSymlinksInPath()
        let path = resolved.path.lowercased()
        // Private engines depend on their owning application's launch environment.
        return executable.isFileURL && ["wine", "wine64"].contains(executable.lastPathComponent)
            && !executable.path.contains(where: \.isNewline)
            && !path.contains("/crossover/bin/") && !path.contains("/contents/sharedsupport/crossover/")
            && !path.contains("/freeruntime/versions/")
            && (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileStore.fm.isExecutableFile(atPath: executable.path)
    }

    public static func detect(applications: [URL], binaries: [URL]) -> URL? {
        let bundleBins = applications.flatMap { app in
            ["Contents/Resources/wine/bin", "Contents/Resources/bin", "Contents/MacOS"].map { app.appendingPathComponent($0) }
        }
        for directory in binaries + bundleBins {
            for name in ["wine", "wine64"] {
                let candidate = directory.appendingPathComponent(name)
                if usable(candidate) { return candidate }
            }
        }
        return nil
    }

    private static let manifest = """
    "compatibilitytools" { "compat_tools" { "macsteamtool-local-wine" { "install_path" "." "display_name" "Local Wine" "from_oslist" "windows" "to_oslist" "macos" } } }
    """
    private static let toolManifest = #""manifest" { "version" "2" "commandline" "/run %verb%" }"#
    // Keep executable paths and game arguments as data, including spaces and shell metacharacters.
    private static let launcher = #"""
    #!/bin/sh
    set -eu
    tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    wine=$(cat "$tool_dir/wine-path")
    case "${STEAM_COMPAT_DATA_PATH:-}" in
        /*/\#(prefixDirectory)) data="$STEAM_COMPAT_DATA_PATH" ;;
        /*) data="$STEAM_COMPAT_DATA_PATH/\#(prefixDirectory)" ;;
        *) exit 2 ;;
    esac
    verb="$1"
    case "$verb" in
        getcompatpath) printf '%s\n' "$data"; exit 0 ;;
        run|waitforexitandrun) shift ;;
        *) exit 2 ;;
    esac
    export WINEPREFIX="$data/pfx"
    export PATH="$(dirname -- "$wine"):$PATH"
    mkdir -p "$data"
    if [ "$verb" = waitforexitandrun ] && [ -d "$WINEPREFIX" ] && [ -x "$(dirname -- "$wine")/wineserver" ]; then
        "$(dirname -- "$wine")/wineserver" -w
    fi
    exec "$wine" "$@"
    """#

    private static func toolDirectory(_ paths: AppPaths) -> URL {
        paths.steam.appendingPathComponent("compatibilitytools.d").appendingPathComponent(toolID)
    }

    private static func isOurTool(_ folder: URL) -> Bool {
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              (try? FileStore.text(folder.appendingPathComponent("compatibilitytool.vdf"))) == manifest,
              (try? FileStore.text(folder.appendingPathComponent("toolmanifest.vdf"))) == toolManifest,
              (try? FileStore.text(folder.appendingPathComponent("run"))) == launcher,
              FileStore.fm.isExecutableFile(atPath: folder.appendingPathComponent("run").path) else { return false }
        return true
    }

    public static func registered(_ paths: AppPaths) -> URL? {
        let folder = toolDirectory(paths)
        guard isOurTool(folder), let path = try? FileStore.text(folder.appendingPathComponent("wine-path")),
              path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        return usable(url) ? url : nil
    }

    public static func isDefault(_ paths: AppPaths) -> Bool {
        guard let bytes = try? FileStore.read(paths.steam.appendingPathComponent("config/config.vdf")) else { return false }
        return (try? SteamCompatibility.globalTool(bytes)) == toolID
    }

    private static func verifyVersion(_ wine: URL, environment: [String: String]) async throws {
        let output = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: output, options: .withoutOverwriting)
        defer { try? FileStore.fm.removeItem(at: output) }
        let handle = try FileHandle(forUpdating: output)
        defer { try? handle.close() }
        let probe = Process()
        probe.executableURL = wine; probe.arguments = ["--version"]; probe.environment = environment
        probe.standardOutput = handle; probe.standardError = handle
        try probe.run()
        defer { if probe.isRunning { kill(probe.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(10)
        while probe.isRunning {
            guard ContinuousClock.now < deadline else { throw AppFailure("本机 Wine 未及时响应，请检查安装后重试 / Local Wine did not respond. Check the installation and retry.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try handle.seek(toOffset: 0)
        let version = String(decoding: try handle.read(upToCount: 4096) ?? Data(), as: UTF8.self)
        guard probe.terminationStatus == 0, version.split(whereSeparator: \.isNewline).contains(where: { $0.range(of: #"^wine-\d"#, options: .regularExpression) != nil }) else {
            throw AppFailure("所选 Wine 未能返回有效版本，请检查安装或选择其他运行器 / The selected Wine could not report a valid version.")
        }
    }

    public static func register(_ wine: URL, paths: AppPaths, home: URL? = nil,
                                requireIdle: @Sendable () throws -> Void = { try GameContainers.requireIdle() }) async throws {
        guard usable(wine) else { throw AppFailure("找不到可用的本机 Wine，请重新检测 / Local Wine is unavailable. Check again.") }
        var env = FreeRuntime.environment()
        if let home { env["HOME"] = home.path; env["CFFIXED_USER_HOME"] = home.path }
        env["PATH"] = wine.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        try await verifyVersion(wine, environment: env)
        try requireIdle()
        let folder = toolDirectory(paths)
        let path = Data(wine.path.utf8)
        if FileStore.fm.fileExists(atPath: folder.path) {
            guard isOurTool(folder) else { throw AppFailure("已有同名 Steam 兼容工具，请检查其安装位置 / This Steam compatibility tool location is already in use.") }
            try FileStore.write(path, to: folder.appendingPathComponent("wine-path"))
            return
        }
        let stage = folder.deletingLastPathComponent().appendingPathComponent(".local-wine-" + UUID().uuidString)
        defer { try? FileStore.fm.removeItem(at: stage) }
        for (name, text) in [("compatibilitytool.vdf", manifest), ("toolmanifest.vdf", toolManifest), ("run", launcher)] {
            try FileStore.write(Data(text.utf8), to: stage.appendingPathComponent(name))
        }
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage.appendingPathComponent("run").path)
        try FileStore.write(path, to: stage.appendingPathComponent("wine-path"))
        try FileStore.fm.moveItem(at: stage, to: folder)
    }
}
