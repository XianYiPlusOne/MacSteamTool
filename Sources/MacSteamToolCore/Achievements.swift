import Foundation
import Darwin

public struct Achievement: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var achieved: Bool
    public var unlockedAt: UInt32
    public init(id: String, name: String, detail: String, achieved: Bool, unlockedAt: UInt32) {
        self.id = id; self.name = name; self.detail = detail; self.achieved = achieved; self.unlockedAt = unlockedAt
    }
}
public struct AchievementChange: Codable, Sendable {
    public var id: String
    public var expected: Bool
    public var achieved: Bool
    public init(id: String, expected: Bool, achieved: Bool) { self.id = id; self.expected = expected; self.achieved = achieved }
}
public struct AchievementRequest: Codable, Sendable {
    public var operation: String?
    public var schemaSourceSteamID: UInt64?
    public var compatibilityRoot: String?
    public var appID: Int
    public var library: String
    public var changes: [AchievementChange]
    public init(appID: Int, library: String, changes: [AchievementChange] = []) { self.appID = appID; self.library = library; self.changes = changes }
    public func validate() throws {
        guard TextUtil.validID(String(appID)) != nil, library.hasPrefix("/"), library.hasSuffix("/steamclient.dylib"), changes.count <= 10_000,
              Set(changes.map(\.id)).count == changes.count, changes.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 1024 && !$0.id.contains("\0") }) else { throw AppFailure("无效的 Steam 成就请求 / Invalid Steam achievement request") }
        if operation == "schema" {
            guard changes.isEmpty, let id = schemaSourceSteamID, id > 76561197960265728, id < 76561202255233024 else { throw AppFailure("无效的公开成就定义来源 / Invalid public schema source") }
        } else if schemaSourceSteamID != nil { throw AppFailure("成就定义请求不能用于编辑 / Schema requests cannot edit achievements") }
        if let root = compatibilityRoot {
            guard root.hasPrefix("/"), !root.contains("\0"), operation == nil || operation == "achievements" else { throw AppFailure("Invalid compatibility statistics root") }
        }
    }
}
public struct AchievementResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String
    public var achievements: [Achievement]
    public var stored: Bool
    public var schemaLoaded: Bool?
    public var backend: String?
    public var serverResult: Int?
    public init(ok: Bool, error: String = "", achievements: [Achievement] = [], stored: Bool = false) {
        self.ok = ok; self.error = error; self.achievements = achievements; self.stored = stored
    }
}
public enum AchievementWorker {
    public static func run(_ request: AchievementRequest, executable: URL) async throws -> AchievementResponse {
        try request.validate()
        guard FileStore.fm.isExecutableFile(atPath: executable.path) else { throw AppFailure("成就子进程不存在，请重新完整打包应用 / Achievement worker missing; rebuild the complete application") }
        let folder = FileStore.fm.temporaryDirectory.appendingPathComponent("MacSteamToolWorker-\(UUID().uuidString)")
        try FileStore.mkdir(folder); try FileStore.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        defer { try? FileStore.fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("request.json"), output = folder.appendingPathComponent("response.json")
        try FileStore.json(request, to: input); try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let process = Process(); process.executableURL = executable; process.arguments = [input.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let task = Task.detached {
            try Task.checkCancellation()
            try process.run()
            let deadline = Date().addingTimeInterval(50)
            while process.isRunning && Date() < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate(); try? await Task.sleep(for: .milliseconds(200))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw AppFailure("Steam 子进程超时或已取消；请重新读取以确认远端状态 / Steam worker timed out or was cancelled; reread to confirm remote state")
            }
            process.waitUntilExit()
            guard FileStore.fm.fileExists(atPath: output.path) else { throw AppFailure("Steam 子进程退出，未返回结果 / Steam worker exited without a result（\(process.terminationStatus)）。当前 Steam 接口可能不兼容 / The current Steam interface may be incompatible") }
            let response = try FileStore.decode(AchievementResponse.self, at: output)
            guard response.ok else {
                if response.error == "Steam callback EResult=2", request.changes.isEmpty { throw AppFailure("Steam 未返回此游戏的成就数据（EResult=2 / Fail）；这不表示成就为空，未执行写入。请确认 Steam 能正常获取该游戏的成就状态 / Steam did not return achievement data for this game (EResult=2 / Fail); this is not an empty list and no changes were written") }
                throw AppFailure(response.error)
            }
            return response
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
