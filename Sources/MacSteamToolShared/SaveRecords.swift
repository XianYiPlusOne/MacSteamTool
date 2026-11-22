import Foundation

public struct GameSaveOptions: Codable, Equatable, Sendable {
    public var backupDirectory = ""
    public var customFolders: [String] = []
    public init() {}
}
public struct GameSaveBackup: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var appID: Int
    public var created = Date()
    public var source: String
    public var directory: String
    public var fileCount: Int
    public var reason: String
    public init(appID: Int, source: URL, directory: URL, fileCount: Int, reason: String) {
        self.appID = appID; self.source = source.path; self.directory = directory.path
        self.fileCount = fileCount; self.reason = reason
    }
}
public struct SaveManagerState: Codable, Sendable {
    public var version = 1
    public var games: [String: GameSaveOptions] = [:]
    public var backups: [GameSaveBackup] = []
    public var pendingReinstallRestores: [Int]? = nil
    public init() {}
    public func options(for appID: Int) -> GameSaveOptions { games[String(appID)] ?? .init() }
    public func backups(for appID: Int) -> [GameSaveBackup] { backups.filter { $0.appID == appID }.sorted { $0.created > $1.created } }
}
