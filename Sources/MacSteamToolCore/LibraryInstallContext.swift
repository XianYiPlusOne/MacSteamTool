import Foundation

public struct LibraryInstallContext: Equatable, Sendable {
    public enum Platform: String, Sendable { case automatic, macos, windows }
    public var platform: Platform
    public var branch: String
    public var language: String?
    public var architecture: String

    public init(platform: Platform = .automatic, branch: String = "public", language: String? = nil, architecture: String = "64") {
        self.platform = platform; self.branch = branch; self.language = language; self.architecture = architecture
    }

    /// Only reads Steam's existing choices. App UI language is not the game's
    /// content language, and the global Windows runner does not force native games.
    public static func read(appID: Int, paths: AppPaths) throws -> Self {
        var context = Self()
        let file = paths.steam.appendingPathComponent("config/config.vdf")
        if FileStore.fm.fileExists(atPath: file.path) {
            let bytes = try FileStore.read(file)
            if let tool = try SteamCompatibility.mapping(bytes, appID: appID)?.string("name"), !tool.isEmpty {
                guard try (tool.hasPrefix("notproton-") || SteamCompatibility.tools(paths: paths).contains(where: { $0.id == tool })) else {
                    throw AppFailure("无法确定已选运行器的平台，请检查游戏的运行器设置 / Could not determine the selected runtime's platform")
                }
                context.platform = .windows
            }
            context.language = try VDF.parse(String(decoding: bytes, as: UTF8.self))
                .object("InstallConfigStore")?.object("Software")?.object("Valve")?.object("Steam")?.string("language")
        }
        let registry = paths.steam.appendingPathComponent("registry.vdf")
        if context.language == nil, FileStore.fm.fileExists(atPath: registry.path) {
            context.language = try VDF.parse(FileStore.text(registry)).object("Registry")?.object("HKCU")?
                .object("Software")?.object("Valve")?.object("Steam")?.string("language")
        }
        for library in SteamLibrary.libraries(paths) {
            let manifest = library.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
            guard FileStore.fm.fileExists(atPath: manifest.path) else { continue }
            guard let app = try VDF.parse(FileStore.text(manifest)).object("AppState"), app.string("appid") == String(appID) else {
                throw AppFailure("游戏安装资料不匹配 / Installed game metadata mismatch")
            }
            if let language = app.object("UserConfig")?.string("language"), !language.isEmpty { context.language = language }
            if let branch = app.object("UserConfig")?.string("BetaKey"), !branch.isEmpty { context.branch = branch }
            break
        }
        if context.language?.isEmpty == true { context.language = nil }
        return context
    }
}
