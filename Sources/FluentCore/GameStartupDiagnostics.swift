import Foundation
import Darwin

/// Read only the selected game's Unity metadata and bounded Player.log sections.
/// The report describes the latest log, never an assumed current Steam session.
public enum GameStartupDiagnostics {
    public enum Status: String, Codable, Sendable { case unavailable, unknown, failed, initialized }
    public struct Report: Codable, Sendable {
        public let status: Status
        public let log: URL?
        public let modifiedAt: Date?
        public let observations: [String]
    }
    public static func parse(_ text: String) -> (Status, [String]) {
        var status = Status.unknown, observations: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            let observation: String?
            if lower.contains("steammanager.initialized = true") {
                status = .initialized; observation = "SteamManager.Initialized = True"
            } else if lower.contains("steammanager.initialized = false") {
                status = .failed; observation = "SteamManager.Initialized = False"
            } else if lower.contains("steamapi_init() failed") || lower.contains("failed to initialize csteamapicontext") {
                status = .failed; observation = "Steam API initialization failed"
            } else if lower.contains("[steamworks.net] could not load [lib]steam_api") {
                status = .failed; observation = "Steam API library could not be loaded"
            } else { observation = nil }
            // Fixed messages only: never copy unrelated log text or credentials.
            if let observation, observations.last != observation { observations.append(observation) }
        }
        return (status, Array(observations.suffix(6)))
    }
    private static func inside(_ file: URL, _ root: URL) -> Bool {
        file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }
    private static func component(_ text: String) -> Bool {
        !text.isEmpty && text != "." && text != ".." && text.utf8.count <= 255 &&
        !text.contains("/") && !text.contains("\\") && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func sample(_ file: URL, limit: Int) throws -> (String, Date) {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        var bytes = try handle.read(upToCount: limit) ?? Data()
        if info.st_size > limit {
            try handle.seek(toOffset: UInt64(max(Int64(limit), info.st_size - Int64(limit))))
            bytes.append(Data("\n".utf8)); bytes.append(try handle.read(upToCount: limit) ?? Data())
        }
        return (String(decoding: bytes, as: UTF8.self), Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }
    public static func inspect(_ game: InstalledGame, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Report {
        let unavailable = Report(status: .unavailable, log: nil, modifiedAt: nil, observations: [])
        var candidates: [URL] = []
        for folder in FileStore.files(game.folder).prefix(80) {
            if folder.lastPathComponent.hasSuffix("_Data") { candidates.append(folder.appendingPathComponent("app.info")) }
            if folder.pathExtension == "app" { candidates.append(folder.appendingPathComponent("Contents/Resources/Data/app.info")) }
        }
        var reports: [Report] = []
        for info in candidates where inside(info, game.folder) {
            guard let size = try? info.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2048,
                  let metadata = try? sample(info, limit: 2048).0 else { continue }
            let parts = metadata.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, component(parts[0]), component(parts[1]) else { continue }
            var roots: [URL] = []
            if let prefix = game.prefix {
                roots = FileStore.files(prefix.appendingPathComponent("drive_c/users")).prefix(16).filter { inside($0, prefix) }.map { $0.appendingPathComponent("AppData/LocalLow") }
            } else { roots = [home.appendingPathComponent("Library/Logs")] }
            for root in roots {
                let log = root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1]).appendingPathComponent("Player.log")
                guard inside(log, root), inside(log, game.prefix ?? root), let (text, date) = try? sample(log, limit: 65536) else { continue }
                let (status, observations) = parse(text)
                reports.append(Report(status: status, log: log, modifiedAt: date, observations: observations))
            }
        }
        return reports.max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) } ?? unavailable
    }
}
