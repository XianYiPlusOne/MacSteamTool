import Foundation
import Security
import Darwin

public struct SteamCredential: Codable, Sendable {
    public var account: String
    public var token: String
    public init(account: String, token: String) { self.account = account; self.token = token }
}
public enum SteamKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.fluentsteam.mac.steamkit", kSecAttrAccount as String: "session"] }
    public static func load() throws -> SteamCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AppFailure("Keychain: \(status)") }
        return try JSONDecoder().decode(SteamCredential.self, from: data)
    }
    public static func save(_ credential: SteamCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Keychain: \(status)") }
    }
    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("Keychain: \(status)") }
    }
}
public struct OwnedGame: Codable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var type: String
}
public struct OwnedDepot: Codable, Sendable {
    public var id: Int
    public var owner: Int
    public var key: String
    public var result: String
    public var manifest: String
    public var sourceApp: Int?
}
public struct ExtractedApp: Codable, Sendable { public var id: Int; public var name: String; public var accessToken: String }
public struct SteamEngineResponse: Decodable, Sendable {
    public var ok: Bool
    public var error: String?
    public var account: String?
    public var token: String?
    public var appID: Int?
    public var name: String?
    public var accessToken: String?
    public var games: [OwnedGame]?
    public var depots: [OwnedDepot]?
    public var extractedApps: [ExtractedApp]?
    public var warnings: [String]?
    public var path: String?
    public var cloudTokens: [String: String]?
    public var fixes: [OnlineFixResult]?
    public var fixDetail: OnlineFixDetail?
    public var patchFiles: [String]?
    public var runtimeRelease: OfficialRuntimeRelease?
    public func lua() throws -> String {
        guard let id = appID, TextUtil.validID(String(id)) != nil else { throw AppFailure("Steam 返回了无效的 AppID / Steam returned an invalid AppID") }
        let title = (name ?? String(id)).components(separatedBy: .newlines).joined(separator: " ")
        var lines = ["-- \(title)", "-- Extracted from the signed-in Steam account", "addappid(\(id))"]
        if let token = accessToken, UInt64(token) != nil, token != "0" { lines.append("addtoken(\(id), \"\(token)\")") }
        let apps = extractedApps ?? Array(Set((depots ?? []).map(\.owner))).map { ExtractedApp(id: $0, name: "", accessToken: "0") }
        guard Set(apps.map(\.id)).count == apps.count, apps.allSatisfy({ TextUtil.validID(String($0.id)) != nil }),
              (depots ?? []).allSatisfy({ TextUtil.validID(String($0.id)) != nil && TextUtil.validID(String($0.owner)) != nil && ($0.sourceApp == nil || TextUtil.validID(String($0.sourceApp!)) != nil) }) else { throw AppFailure("提取结果包含无效或重复 AppID / Invalid or duplicate AppID in extraction result") }
        var seen = Set<Int>()
        for app in ([ExtractedApp(id: id, name: title, accessToken: accessToken ?? "0")] + apps.filter { $0.id != id }.sorted { $0.id < $1.id }) {
            if app.id != id {
                lines.append("addappid(\(app.id)) -- \(TextUtil.cleanLine(app.name))")
                if let token = UInt64(app.accessToken), token > 0 { lines.append("addtoken(\(app.id), \"\(token)\")") }
            }
            for depot in (depots ?? []).filter({ $0.owner == app.id }).sorted(by: { $0.id < $1.id }) {
                guard seen.insert(depot.id).inserted else { continue }
                guard TextUtil.validKey(depot.key) else { lines.append("-- Depot \(depot.id): \(TextUtil.cleanLine(depot.result))"); continue }
                lines.append("addappid(\(depot.id), 1, \"\(depot.key)\")")
                if let manifest = UInt64(depot.manifest), manifest > 0 { lines.append("setManifestid(\(depot.id), \"\(manifest)\")") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
public struct SteamEngineRequest: Encodable, Sendable {
    public var operation: String
    public var account = ""
    public var token = ""
    public var appID = 0
    public var depotID = 0
    public var manifestID: UInt64 = 0
    public var depotKey = ""
    public var destination = ""
    public var mirror: String?
    public var provider = ""
    public var query = ""
    public var url = ""
    public var referer = ""
    public var archive = ""
    public var password = ""
    public var steamPath = ""
    public var steamID = ""
    public var includeDLC = true
    public var runtimeRelease: OfficialRuntimeRelease?
    public init(_ operation: String, credential: SteamCredential? = nil, appID: Int = 0) {
        self.operation = operation; self.account = credential?.account ?? ""; self.token = credential?.token ?? ""; self.appID = appID
    }
}
public enum SteamEngine {
    public static func run(_ request: SteamEngineRequest, executable: URL, status: @escaping @Sendable (String) async -> Void = { _ in }, challenge: @escaping @Sendable (String) async -> String? = { _ in nil }) async throws -> SteamEngineResponse {
        guard FileStore.fm.isExecutableFile(atPath: executable.path) else { throw AppFailure("SteamKit 引擎不存在，请重新完整打包应用 / SteamKit engine missing; rebuild the complete application") }
        let folder = FileStore.fm.temporaryDirectory.appendingPathComponent("FluentSteamSession-\(UUID().uuidString)")
        try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileStore.fm.removeItem(at: folder) }
        let input = folder.appendingPathComponent("request.json"), output = folder.appendingPathComponent("response.json")
        try FileStore.json(request, to: input); try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        let process = Process(); process.executableURL = executable; process.arguments = [input.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let task = Task.detached {
            try Task.checkCancellation(); try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
            let deadline = Date().addingTimeInterval(["login", "login-password", "login-local", "cloud-oauth"].contains(request.operation) ? 190 : ["onlinefix-download", "patch-extract", "library-import", "tool-download", "runtime-download", "extract"].contains(request.operation) ? 910 : 130)
            var last = "", lastChallenge = ""
            while process.isRunning && Date() < deadline && !Task.isCancelled {
                if let data = try? FileStore.read(URL(fileURLWithPath: output.path + ".status")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String], let url = json["url"], url != last {
                    last = url; await status(url)
                }
                let statusFile = URL(fileURLWithPath: output.path + ".status")
                if let data = try? FileStore.read(statusFile), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   json["state"] == "guard", let id = json["requestID"], id != lastChallenge {
                    lastChallenge = id
                    let code = await challenge(json["prompt"] ?? "Steam Guard")
                    let reply = URL(fileURLWithPath: statusFile.path + ".reply")
                    try FileStore.json(["requestID": id, "code": code ?? ""], to: reply)
                    try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reply.path)
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if process.isRunning {
                process.terminate(); try? await Task.sleep(for: .milliseconds(250))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); throw AppFailure("SteamKit 会话已取消或超时 / SteamKit session cancelled or timed out")
            }
            process.waitUntilExit()
            guard FileStore.fm.fileExists(atPath: output.path) else { throw AppFailure("SteamKit 进程未返回结果 / SteamKit process returned no result（\(process.terminationStatus)）") }
            let result = try FileStore.decode(SteamEngineResponse.self, at: output)
            guard result.ok else { throw AppFailure(result.error ?? "SteamKit 请求失败 / SteamKit request failed") }
            return result
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
