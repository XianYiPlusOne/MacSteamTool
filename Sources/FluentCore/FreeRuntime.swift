import Foundation
import CryptoKit
import Darwin

/// An independently registered Steam tool. It never edits NotProton's paid runners.
public enum FreeRuntime {
    public static let toolID = "fluent-proton-free"
    public static let release = "2026.10.13-e350a87"
    public static let digest = "4d2446faa89f8c72838ca419df5b76d76a8d9ac52bea11cb47dd731ea83f85a8"
    public static let assetName = "steamplay-mac-\(release).dmg"
    public static let downloadURL = URL(string: "https://github.com/Drustburn/steamplay-mac/releases/download/v2026.10.13/\(assetName)")!
    public static func root(_ paths: AppPaths) -> URL { paths.data.appendingPathComponent("FreeRuntime") }
    public static func tool(_ paths: AppPaths) -> URL { paths.steam.appendingPathComponent("compatibilitytools.d/\(toolID)") }
    public static func installedRoot(_ paths: AppPaths) -> URL? {
        guard let value = try? FileStore.text(tool(paths).appendingPathComponent("runtime-root")),
              !value.contains("\n"), value.hasPrefix(root(paths).path + "/versions/") else { return nil }
        let url = URL(fileURLWithPath: value)
        guard FileStore.fm.isExecutableFile(atPath: url.appendingPathComponent("runner/bin/wineserver").path),
              FileStore.fm.isExecutableFile(atPath: url.appendingPathComponent("runner/lib/wine/x86_64-unix/wine").path),
              ["receipt.json", "bridge/steamclient64.dll", "bridge/steam.exe", "runner/lib/renderers/dxmt/x86_64-windows/d3d11.dll"].allSatisfy({ FileStore.fm.fileExists(atPath: url.appendingPathComponent($0).path) }),
              FileStore.fm.isExecutableFile(atPath: tool(paths).appendingPathComponent("run").path),
              FileStore.fm.fileExists(atPath: tool(paths).appendingPathComponent("prefix-support-ready").path) else { return nil }
        return url
    }
    /// Legacy installations remain usable until the staged upgrade commits.
    public static func graphicsReady(_ paths: AppPaths) -> Bool {
        guard let root = installedRoot(paths),
              (try? FileStore.text(tool(paths).appendingPathComponent("defaults-root"))) == paths.notProton.path else { return false }
        let dxvk = ["x86_64-windows", "i386-windows"].flatMap { arch in
            ["d3d10core", "d3d11"].map { "runner/lib/renderers/dxvk/\(arch)/\($0).dll" }
        }
        let d3dmetal = ["d3d11", "d3d12", "dxgi"].map { "runner/lib/renderers/d3dmetal/x86_64-windows/\($0).dll" }
        return (dxvk + d3dmetal + ["compat-defaults.sh", "compat-prefix.sh", "runner/lib/external/libd3dshared.dylib",
                "runner/lib/external/D3DMetal.framework/D3DMetal"]).allSatisfy { FileStore.fm.fileExists(atPath: root.appendingPathComponent($0).path) }
    }
    public static func selected(_ data: Data?, appID: Int) -> Bool {
        guard let data else { return false }
        // An explicit empty mapping is a manual choice, not the global default.
        if let mapping = try? SteamCompatibility.mapping(data, appID: appID) { return mapping.string("name") == toolID }
        return (try? SteamCompatibility.globalTool(data)) == toolID
    }
    public static func prefix(in compatibilityData: URL) -> URL { compatibilityData.appendingPathComponent("fluent-free/pfx") }

    public static func install(paths: AppPaths, resources: URL, archive supplied: URL? = nil, cloudHelper: URL? = nil,
                               steamRunning: @escaping @Sendable () -> Bool = { SteamProcesses.isRunning },
                               progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        let fm = FileStore.fm, support = root(paths), lock = support.appendingPathComponent("install.lock")
        try FileStore.mkdir(support)
        // Respect an older installer, while new installations use an OS lock
        // that is released even if the app exits unexpectedly.
        guard !fm.fileExists(atPath: lock.path) else { throw AppFailure("检测到旧版安装锁，请检查 \(lock.path) / A legacy runtime installation lock needs inspection") }
        let fd = open(support.appendingPathComponent(".installation-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppFailure("无法锁定免费运行器 / Cannot lock the free runtime") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("免费运行器正在安装 / Free runtime installation is already running") }
        let id = UUID().uuidString, version = support.appendingPathComponent("versions/\(release)-\(id)")
        let stagedTool = support.appendingPathComponent("tool-\(id)"), target = tool(paths)
        let backup = support.appendingPathComponent("backups/\(id)")
        var committed = false, movedOld = false
        defer { if !committed { try? fm.removeItem(at: version); try? fm.removeItem(at: stagedTool) } }
        try FileStore.mkdir(version); try FileStore.mkdir(stagedTool)
        let cache = paths.cache.appendingPathComponent("FreeRuntime")
        try FileStore.mkdir(cache)
        let archive = try await prepareArchive(paths: paths, archive: supplied, progress: progress)
        try reuseValvePackages(paths: paths, resources: resources)
        await progress("安装图形后端与 Steam 桥接组件 / Preparing graphics backends and Steam bridge…")
        let (status, output) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"),
            [resources.appendingPathComponent("prepare.sh").path, archive.path, version.path, cache.path], environment: environment())
        guard status == 0 else { throw AppFailure("免费运行器安装失败 / Free runtime preparation failed:\n\(output.suffix(4000))") }
        if let previous = installedRoot(paths) {
            let legacy = previous.appendingPathComponent("global.env")
            if fm.fileExists(atPath: legacy.path) { try FileStore.write(FileStore.read(legacy), to: version.appendingPathComponent("global.env")) }
        }
        try FileStore.json(["release": release, "sha256": digest, "graphics": "DXMT, DXVK, WineD3D, D3DMetal"], to: version.appendingPathComponent("receipt.json"))
        try fm.copyItem(at: resources.appendingPathComponent("run"), to: stagedTool.appendingPathComponent("run"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedTool.appendingPathComponent("run").path)
        try Data(paths.notProton.path.utf8).write(to: stagedTool.appendingPathComponent("defaults-root"))
        try Data(version.path.utf8).write(to: stagedTool.appendingPathComponent("runtime-root"))
        try Data("fluent-free-v1".utf8).write(to: stagedTool.appendingPathComponent("fluent-owner"))
        try Data("\"compatibilitytools\" { \"compat_tools\" { \"\(toolID)\" { \"install_path\" \".\" \"display_name\" \"Fluent Wine (Experimental)\" \"from_oslist\" \"windows\" \"to_oslist\" \"macos\" } } }\n".utf8).write(to: stagedTool.appendingPathComponent("compatibilitytool.vdf"))
        try Data("\"manifest\" { \"version\" \"2\" \"commandline\" \"/run %verb%\" }\n".utf8).write(to: stagedTool.appendingPathComponent("toolmanifest.vdf"))
        guard !steamRunning() else { throw AppFailure("请退出 Steam 后重试；下载已缓存 / Quit Steam and retry; download is cached") }
        // Older CloudRedirect versions resolve all Windows saves to the paid
        // prefix. Update that optional extension before exposing the new tool.
        if RuntimeStatus.read(paths).injectedLibraries.contains(where: { $0.hasSuffix("/cloud_redirect.dylib") }) {
            guard let cloudHelper else { throw AppFailure("需要本应用的云存档扩展以支持独立前缀 / The bundled cloud extension is required for separate prefixes") }
            let live = paths.steamApp.appendingPathComponent("Contents/MacOS/cloud_redirect.dylib")
            if (try? FileStore.read(live)) != (try FileStore.read(cloudHelper)) {
                _ = try await KernelDeployment.deploy(name: "cloud_redirect.dylib", source: cloudHelper, paths: paths)
            }
        }
        try Data("fluent-free-v1".utf8).write(to: stagedTool.appendingPathComponent("prefix-support-ready"))
        guard !steamRunning() else { throw AppFailure("Steam 已启动，未注册运行器；请退出后重试 / Steam started; quit and retry registration") }
        try FileStore.mkdir(target.deletingLastPathComponent()); try FileStore.mkdir(backup.deletingLastPathComponent())
        if fm.fileExists(atPath: target.path) {
            guard (try? FileStore.text(target.appendingPathComponent("fluent-owner"))) == "fluent-free-v1" else { throw AppFailure("同名兼容工具不由 Fluent 管理 / Existing tool is not managed by Fluent") }
            try fm.moveItem(at: target, to: backup); movedOld = true
        }
        do { try fm.moveItem(at: stagedTool, to: target); committed = true }
        catch { if movedOld { try? fm.moveItem(at: backup, to: target) }; throw error }
        await progress("免费运行器已安装。启动 Steam 后，在游戏兼容性中选择 Fluent Wine / Free runtime installed; select Fluent Wine in game compatibility")
    }

    public static func prepareArchive(paths: AppPaths, archive supplied: URL? = nil,
                                      progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        let fm = FileStore.fm, cache = paths.cache.appendingPathComponent("FreeRuntime")
        try FileStore.mkdir(cache)
        let archive = supplied ?? cache.appendingPathComponent(assetName)
        if supplied == nil && !fm.fileExists(atPath: archive.path) {
            await progress("下载 Wine 运行器 / Downloading Wine runtime…")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (temporary, response) = try await session.download(from: downloadURL)
            defer { try? fm.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure("免费运行器下载失败 / Free runtime download failed") }
            try fm.moveItem(at: temporary, to: archive)
        }
        await progress("校验免费运行器 / Verifying free runtime…")
        let verified = try await Task.detached {
            let file = try FileHandle(forReadingFrom: archive); defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
        }.value
        guard verified else {
            if supplied == nil { try? fm.removeItem(at: archive) }
            throw AppFailure("运行器摘要不匹配，未安装 / Runtime digest mismatch; not installed")
        }
        return archive
    }

    /// NotProton and Fluent Wine pin the same Valve packages. Reuse only files
    /// matching the free runtime's own manifest; prepare.sh verifies them again.
    static func reuseValvePackages(paths: AppPaths, resources: URL) throws {
        let source = paths.cache.appendingPathComponent("ValvePackages")
        let target = paths.cache.appendingPathComponent("FreeRuntime/valve")
        try FileStore.mkdir(target)
        for line in try FileStore.text(resources.appendingPathComponent("valve-packages.manifest")).split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 4, parts[0] == "package", !parts[2].contains("/"), parts[2] != ".", parts[2] != ".." else { continue }
            let from = source.appendingPathComponent(parts[2]), to = target.appendingPathComponent(parts[2])
            if !FileStore.fm.fileExists(atPath: to.path), let bytes = try? FileStore.read(from), FileStore.hash(bytes) == parts[3] {
                try FileStore.write(bytes, to: to)
            }
        }
    }

    /// Do not forward unrelated credentials from developer shells into Wine.
    public static func environment() -> [String: String] {
        let original = ProcessInfo.processInfo.environment
        var env = original.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }
    public static func launch(appID: Int, command: String, prefix: URL, paths: AppPaths) throws -> WineLaunch {
        guard let root = installedRoot(paths) else { throw AppFailure("请先安装或修复免费运行器 / Install or repair the free runtime first") }
        let runner = root.appendingPathComponent("runner"), loader = runner.appendingPathComponent("lib/wine/x86_64-unix/wine")
        var env = environment()
        env["WINEPREFIX"] = prefix.path; env["WINELOADER"] = loader.path
        env["WINESERVER"] = runner.appendingPathComponent("bin/wineserver").path
        env["CX_ROOT"] = runner.path; env["CX_HOME"] = root.appendingPathComponent("wine-config").path
        env["SteamAppId"] = String(appID); env["SteamGameId"] = String(appID)
        env["WINEDLLPATH"] = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam").path + ":" + runner.appendingPathComponent("lib/wine/x86_64-windows").path + ":" + runner.appendingPathComponent("lib/wine/x86_64-unix").path
        env["WINEDLLOVERRIDES"] = "steamclient=n;steamclient64=n;lsteamclient=b"
        env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS").path
        try RunnerCompatibility(wine: true, build: nil, fex: false, paths: paths)
            .configureTool(runner: runner, prefix: prefix, environment: &env)
        let args = command.lowercased().hasSuffix(".msi") ? ["msiexec", "/i", command] : [command]
        return WineLaunch(executable: loader, arguments: args, environment: env, prefix: prefix)
    }
}
