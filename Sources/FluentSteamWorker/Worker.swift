import Foundation
import FluentCore
import NativeSteam

@main struct Worker {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else { exit(2) }
        let result: AchievementResponse
        do { result = try execute(FileStore.decode(AchievementRequest.self, at: URL(fileURLWithPath: args[1]))) }
        catch { result = AchievementResponse(ok: false, error: error.localizedDescription) }
        do {
            let output = URL(fileURLWithPath: args[2]); try FileStore.json(result, to: output)
            try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        } catch { exit(3) }
        exit(result.ok ? 0 : 1)
    }
    static func execute(_ request: AchievementRequest) throws -> AchievementResponse {
        try request.validate()
        if request.operation == "tickets" { return try tickets(request) }
        if request.operation == "schema" {
            guard let source = request.schemaSourceSteamID, let context = fs_create_session(request.library, UInt32(request.appID), 0) else { throw AppFailure("Cannot create schema session") }
            defer { fs_destroy(context) }
            guard fs_schema(context, source) != 0 else { throw AppFailure(String(cString: fs_error(context))) }
            var result = AchievementResponse(ok: true); result.schemaLoaded = true; return result
        }
        guard request.operation == nil || request.operation == "achievements" else { throw AppFailure("Unknown worker operation") }
        guard let context = fs_create(request.library, UInt32(request.appID)) else { throw AppFailure("Cannot create Steam context") }
        defer { fs_destroy(context) }
        guard fs_ready(context) != 0 else { throw AppFailure(String(cString: fs_error(context))) }
        let compatibilityRoot = request.compatibilityRoot.map { URL(fileURLWithPath: $0) }
        let compatible = compatibilityRoot.map { CompatibilityAchievements.active(root: $0, appID: request.appID) } ?? false
        guard compatibilityRoot == nil || compatible else { throw AppFailure("兼容成就设置尚未加载或配置已变化，请重启 Steam 后重试 / Compatibility settings are not active; restart Steam before retrying") }
        let count = fs_count(context)
        guard count <= 10_000 else { throw AppFailure("Steam returned an invalid achievement count") }
        var rows: [Achievement] = []
        for index in 0..<count {
            guard let key = fs_name(context, index), strnlen(key, 1025) <= 1024 else { throw AppFailure("Invalid achievement identifier") }
            let id = String(cString: key)
            var time: UInt32 = 0
            let value = fs_get(context, id, &time)
            guard value >= 0 else { throw AppFailure("Could not read achievement: \(id)") }
            func attribute(_ name: String) -> String {
                guard let value = fs_attribute(context, id, name), strnlen(value, 8193) <= 8192 else { return "" }
                return String(cString: value)
            }
            rows.append(Achievement(id: id, name: attribute("name"), detail: attribute("desc"), achieved: value == 1, unlockedAt: time))
        }
        // Validate the complete edit set before staging any changes in Steam's cache.
        // A concurrent save/retry may already have applied the requested boolean.
        // Accept that state without setting it again (and changing its unlock time).
        var pendingChanges: [AchievementChange] = []
        for change in request.changes {
            guard let row = rows.first(where: { $0.id == change.id }) else { throw AppFailure("成就已不存在，请重新读取 / Achievement no longer exists: \(change.id). Reload before saving.") }
            if row.achieved == change.achieved { continue }
            guard row.achieved == change.expected else { throw AppFailure("成就状态已变化，请重新读取 / Achievement changed since it was loaded: \(change.id). Reload before saving.") }
            pendingChanges.append(change)
        }
        var serverResult: Int?
        if !request.changes.isEmpty {
            for (index, change) in pendingChanges.enumerated() {
                guard fs_set(context, change.id, change.achieved ? 1 : 0) != 0 else {
                    for prior in pendingChanges.prefix(index) { _ = fs_set(context, prior.id, prior.expected ? 1 : 0) }
                    throw AppFailure("Steam refused an achievement change: \(change.id)")
                }
            }
            if fs_store(context) == 0 {
                let failure = String(cString: fs_error(context))
                guard compatible, failure == "Steam callback EResult=2" else { throw AppFailure(failure + ". Reload to check the actual remote state.") }
                serverResult = 2
            } else { serverResult = 1 }
            guard fs_refresh(context) != 0 else { throw AppFailure("Saved request, but reloading current-user statistics failed: " + String(cString: fs_error(context))) }
            for i in rows.indices {
                var time: UInt32 = 0
                let value = fs_get(context, rows[i].id, &time)
                guard value >= 0 else { throw AppFailure("Saved, but could not reload the achievement state") }
                rows[i].achieved = value == 1; rows[i].unlockedAt = time
            }
            for change in request.changes {
                guard rows.first(where: { $0.id == change.id })?.achieved == change.achieved else {
                    throw AppFailure("保存后成就状态与请求不一致，请重新读取 / Saved achievement state did not match the request: \(change.id). Reload before editing.")
                }
            }
            if compatible, let root = compatibilityRoot {
                guard CompatibilityAchievements.active(root: root, appID: request.appID) else { throw AppFailure("Compatibility configuration changed while saving; reload first") }
                try CompatibilityAchievements.verify(root: root, account: fs_account(context), appID: request.appID, rows: rows, changes: request.changes)
            }
        }
        var result = AchievementResponse(ok: true, achievements: rows, stored: !request.changes.isEmpty)
        result.backend = compatible ? "compatibility" : "steam"; result.serverResult = serverResult
        return result
    }
    static func tickets(_ request: AchievementRequest) throws -> AchievementResponse {
        guard request.changes.isEmpty else { throw AppFailure("Ticket requests cannot contain achievement changes") }
        guard let context = fs_create_session(request.library, UInt32(request.appID), 0) else { throw AppFailure("Cannot create Steam context") }
        defer { fs_destroy(context) }
        guard fs_ready(context) != 0 else { throw AppFailure(String(cString: fs_error(context))) }
        var ownership = [UInt8](repeating: 0, count: 4096), encrypted = [UInt8](repeating: 0, count: 4096)
        var ownershipSize: UInt32 = 0, encryptedSize: UInt32 = 0
        guard fs_tickets(context, &ownership, 4096, &ownershipSize, &encrypted, 4096, &encryptedSize) != 0 else { throw AppFailure(String(cString: fs_error(context))) }
        var result = AchievementResponse(ok: true)
        result.ownershipTicket = Data(ownership.prefix(Int(ownershipSize)))
        result.encryptedTicket = Data(encrypted.prefix(Int(encryptedSize)))
        return result
    }
}
