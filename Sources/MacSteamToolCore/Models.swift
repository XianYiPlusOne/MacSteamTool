import Foundation

public struct AppFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AppPaths: Sendable {
    public var steam: URL
    public var macSteam: URL
    public var notProton: URL
    public var data: URL
    public var lua: URL
    public var steamApp: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, data: URL? = nil) {
        let support = home.resolvingSymlinksInPath().appendingPathComponent("Library/Application Support")
        steam = support.appendingPathComponent("Steam")
        macSteam = support.appendingPathComponent("macsteam")
        notProton = support.appendingPathComponent("notproton")
        let current = support.appendingPathComponent("MacSteamTool")
        let legacy = support.appendingPathComponent("FluentSteamMac")
        // Older backups contain absolute paths. Open those installations in place.
        let useLegacy = !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path)
        self.data = data ?? (useLegacy ? legacy : current)
        lua = self.data.appendingPathComponent("Lua")
        steamApp = URL(fileURLWithPath: "/Applications/Steam.app")
    }
    public var config: URL { macSteam.appendingPathComponent("config.yaml") }
    public var backups: URL { data.appendingPathComponent("Backups") }
    public var cache: URL { data.appendingPathComponent("Cache") }
    public var depotCache: URL { steam.appendingPathComponent("depotcache") }
    public var settings: URL { data.appendingPathComponent("settings.json") }
    public var disabled: URL { lua.appendingPathComponent("Disable") }
}

public struct Preferences: Codable, Sendable {
    public var steamPath = ""
    public var steamAppPath = "/Applications/Steam.app"
    public var macSteamPath = ""
    public var notProtonPath = ""
    public var luaPath = ""
    public var language = "zh"
    public var theme = "system"
    public var layout = "cards"
    public var autoRefresh = true
    public var autoMetadata = true
    public var automaticallyPrepareAchievements: Bool?
    public var depotKeysURL = "https://api.993499094.xyz/depotkeys.json"
    public var tokensURL = "https://api.993499094.xyz/appaccesstokens.json"
    public var manifestURL = "https://steamapi.993499094.xyz/manifest/{depot}/{manifest}"
    public var manifestFallbacks: Bool? = true
    public var remotePackageURL: String?
    public var remotePackageMode: String?
    public var manifestSource: String?
    public var automaticallyCheckRuntimeUpdates: Bool?
    public var updateFeed: String?
    public var automaticallyCheckUpdates: Bool?
    public var downloadMirror: String?
    public var preferredCDN: String?
    public var materialBackground: Bool?
    public init() {}
    public func applying(to defaults: AppPaths) -> AppPaths {
        var p = defaults
        if !steamPath.isEmpty { p.steam = URL(fileURLWithPath: steamPath) }
        if !steamAppPath.isEmpty { p.steamApp = URL(fileURLWithPath: steamAppPath) }
        if !macSteamPath.isEmpty { p.macSteam = URL(fileURLWithPath: macSteamPath) }
        if !notProtonPath.isEmpty { p.notProton = URL(fileURLWithPath: notProtonPath) }
        if !luaPath.isEmpty { p.lua = URL(fileURLWithPath: luaPath) }
        return p
    }
}

public struct Game: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var luaURL: URL?
    public var enabled: Bool
    public var installed: InstalledGame?
    public var dlcIDs: [Int]
    public var depotCount: Int
    public var source: String
    public var warnings: [String]
    public init(id: Int, name: String, luaURL: URL? = nil, enabled: Bool = false,
                installed: InstalledGame? = nil, dlcIDs: [Int] = [], depotCount: Int = 0,
                source: String = "macSteam", warnings: [String] = []) {
        self.id = id; self.name = name; self.luaURL = luaURL; self.enabled = enabled
        self.installed = installed; self.dlcIDs = dlcIDs; self.depotCount = depotCount
        self.source = source; self.warnings = warnings
    }
}

public struct InstalledGame: Hashable, Sendable {
    public var id: Int
    public var name: String
    public var library: URL
    public var folder: URL
    public var buildID: String
    public var bytes: Int64
    public var depots: [Int: String]
    public var prefix: URL? {
        let p = selectedPrefix ?? library.appendingPathComponent("steamapps/compatdata/\(id)/pfx")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
    public var selectedPrefix: URL? = nil
}

public struct GameMetadata: Codable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var image: String
    public var description: String
    public var mac: Bool
    public var windows: Bool
    public var dlc: [Int]
    public init(id: Int, name: String, image: String = "", description: String = "", mac: Bool = false, windows: Bool = false, dlc: [Int] = []) {
        self.id = id; self.name = name; self.image = image; self.description = description
        self.mac = mac; self.windows = windows; self.dlc = dlc
    }
}

public struct BackupRecord: Identifiable, Codable, Sendable {
    public var id: String
    public var date: Date
    public var reason: String
    public var files: [BackupFile]
    public var libraryAppIDs: [Int]? = nil
}
public struct BackupFile: Codable, Sendable {
    public var original: String
    public var stored: String
    public var sha256: String
    public var existed: Bool
}

public enum TextUtil {
    public static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    public static func cleanLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\0", with: "")
    }
    public static func validID(_ value: String) -> Int? {
        guard let id = UInt32(value), id > 0 else { return nil }; return Int(id)
    }
    public static func validKey(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}
