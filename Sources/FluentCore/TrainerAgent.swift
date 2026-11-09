import Foundation
import Darwin

public struct TrainerAgentStatus: Codable {
    public var date: Date
    public var bindings: [String: String]
    public init(date: Date = Date(), bindings: [String: String]) { self.date = date; self.bindings = bindings }
}
public enum TrainerAgentService {
    public static let label = "dev.fluentsteam.mac.trainer-agent"
    public static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    public static func configuration(executable: URL, settings: URL, log: URL) throws -> Data {
        guard executable.path.hasPrefix("/"), settings.path.hasPrefix("/") else { throw AppFailure("Agent paths must be absolute") }
        return try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [executable.path, settings.path], "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 15, "StandardOutPath": log.path, "StandardErrorPath": log.path, "ProcessType": "Background"], format: .xml, options: 0)
    }
    public static func configure(enabled: Bool, executable: URL, settings: URL, log: URL) throws {
        let file = plistURL, domain = "gui/\(getuid())"
        if enabled {
            guard FileStore.fm.isExecutableFile(atPath: executable.path) else { throw AppFailure("后台助手缺失，请安装完整应用 / Background helper missing; install the complete application") }
            let data = try configuration(executable: executable, settings: settings, log: log)
            if (try? FileStore.read(file)) == data, try launchctl(["print", "\(domain)/\(label)"]) == 0 { return }
            try FileStore.mkdir(log.deletingLastPathComponent())
            if FileStore.fm.fileExists(atPath: file.path) { _ = try launchctl(["bootout", "\(domain)/\(label)"]) }
            try FileStore.write(data, to: file)
            let status = try launchctl(["bootstrap", domain, file.path])
            guard status == 0 else { try? FileStore.fm.removeItem(at: file); throw AppFailure("launchctl bootstrap: \(status)") }
        } else if FileStore.fm.fileExists(atPath: file.path) {
            let code = try launchctl(["bootout", "\(domain)/\(label)"])
            guard code == 0 || code == 3 || code == 113 else { throw AppFailure("launchctl bootout: \(code)") }
            try FileStore.fm.removeItem(at: file)
        }
    }
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
}
