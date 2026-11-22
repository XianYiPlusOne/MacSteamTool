import Foundation

public enum NativeSteamBootstrap {
    public static let bundleIdentifier = "com.valvesoftware.steam"
    public static let download = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/steam.dmg")!
    public static func isSteamApplication(_ app: URL) -> Bool {
        guard app.pathExtension.lowercased() == "app",
              let data = try? FileStore.read(app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String, executable == "steam_osx" else { return false }
        let binary = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        return (try? binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileStore.fm.isExecutableFile(atPath: binary.path)
    }
    public static func validate(_ app: URL) async throws {
        let info = try PropertyListSerialization.propertyList(from: FileStore.read(app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier,
              FileStore.fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/steam_osx").path) else { throw AppFailure("下载中缺少原生 Steam / Native Steam missing from download") }
        let valveSignature = #"anchor apple generic and identifier "com.valvesoftware.steam" and certificate leaf[subject.OU] = "MXGJJ98X76""#
        let (status, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", "-R=" + valveSignature, app.path])
        guard status == 0 else { throw AppFailure("Steam 的 Valve 签名校验失败 / Steam Valve signature verification failed") }
        try OfficialRuntimeUpdates.validateLinks(app)
    }
    public static func prepare(cache: URL, archive: URL? = nil) async throws -> URL {
        try FileStore.mkdir(cache)
        let app = cache.appendingPathComponent("Steam.app")
        if FileStore.fm.fileExists(atPath: app.path), (try? await validate(app)) != nil { return app }
        let stage = cache.appendingPathComponent(UUID().uuidString); try FileStore.mkdir(stage)
        defer { try? FileStore.fm.removeItem(at: stage) }
        let dmg: URL
        if let archive { dmg = archive }
        else {
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let (temporary, response) = try await session.download(from: download)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
                  response.url?.host == download.host, ((try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) < 64 * 1024 * 1024 else { throw AppFailure("Steam 下载失败 / Steam download failed") }
            dmg = stage.appendingPathComponent("steam.dmg"); try FileStore.fm.moveItem(at: temporary, to: dmg)
        }
        let mount = stage.appendingPathComponent("mount"); try FileStore.mkdir(mount)
        let (status, detail) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        guard status == 0 else { throw AppFailure("无法挂载 Steam 安装包 / Cannot mount Steam installer: \(detail.suffix(1000))") }
        let candidate = stage.appendingPathComponent("Steam.app")
        do {
            try await validate(mount.appendingPathComponent("Steam.app"))
            try FileStore.fm.copyItem(at: mount.appendingPathComponent("Steam.app"), to: candidate)
        } catch {
            _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path]); throw error
        }
        let (detached, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path])
        guard detached == 0 else { throw AppFailure("Steam 安装镜像未能卸载 / Could not detach Steam installer") }
        if FileStore.fm.fileExists(atPath: app.path) { try FileStore.fm.moveItem(at: app, to: cache.appendingPathComponent("previous-\(UUID().uuidString).app")) }
        try FileStore.fm.moveItem(at: candidate, to: app); return app
    }
    /// Only fills an absent application. Existing Steam installations are retained.
    public static func install(_ prepared: URL, at target: URL) async throws {
        guard !FileStore.fm.fileExists(atPath: target.path) else { return }
        try await validate(prepared); try FileStore.mkdir(target.deletingLastPathComponent())
        let stage = target.deletingLastPathComponent().appendingPathComponent(".macsteamtool-\(UUID().uuidString).app")
        defer { try? FileStore.fm.removeItem(at: stage) }
        try FileStore.fm.copyItem(at: prepared, to: stage)
        try await validate(stage)
        try FileStore.fm.moveItem(at: stage, to: target)
    }
}
