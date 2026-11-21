import Foundation

public enum NativeSteamBootstrap {
    public static let download = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/steam.dmg")!
    public static func validate(_ app: URL) async throws {
        let info = try PropertyListSerialization.propertyList(from: FileStore.read(app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "com.valvesoftware.steam",
              FileStore.fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/steam_osx").path) else { throw AppFailure("下载中缺少原生 Steam / Native Steam missing from download") }
        let (status, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
        let (_, detail) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["-dv", "--verbose=4", app.path])
        guard status == 0, detail.contains("TeamIdentifier=MXGJJ98X76"), detail.contains("Authority=Developer ID Application: Valve Corporation") else { throw AppFailure("Steam 的 Valve 签名校验失败 / Steam Valve signature verification failed") }
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
        let stage = target.deletingLastPathComponent().appendingPathComponent(".fluent-steam-\(UUID().uuidString).app")
        defer { try? FileStore.fm.removeItem(at: stage) }
        try FileStore.fm.copyItem(at: prepared, to: stage)
        try await validate(stage)
        try FileStore.fm.moveItem(at: stage, to: target)
    }
}
