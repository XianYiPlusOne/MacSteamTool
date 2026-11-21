import Foundation

public struct SteamGenerationApp: Decodable, Sendable {
    public let id: Int
    public let accessToken: String
    public let productInfo: String?
}

/// One generation operation. Account-specific product data stays in memory.
public actor LuaGenerationMetadata {
    public typealias PublicLookup = @Sendable (Int) async throws -> AppInfo
    public typealias SteamLookup = @Sendable ([Int], [Int]) async throws -> [SteamGenerationApp]

    private let publicInfo: PublicLookup
    private var steam: SteamLookup?
    private let includeDLC: Bool
    private let excluded: Set<Int>
    private var pendingDLC = Set<Int>()
    private var infos: [Int: Result<AppInfo, Error>] = [:]
    private var tokens: [Int: String] = [:]
    public private(set) var notices: [String] = []

    public init(includeDLC: Bool, excludingDLC: Set<Int> = [], publicInfo: @escaping PublicLookup, steam: SteamLookup? = nil) {
        self.includeDLC = includeDLC
        excluded = excludingDLC
        self.publicInfo = publicInfo
        self.steam = steam
    }

    public func appInfo(_ id: Int) async throws -> AppInfo {
        try Task.checkCancellation()
        if infos[id] == nil {
            guard steam != nil else { return try await publicInfo(id) }
            // Group siblings in one SteamKit login. Only fetch groups as traversal reaches them.
            var ids = [id]
            if pendingDLC.remove(id) != nil {
                ids += pendingDLC.sorted().prefix(15)
                pendingDLC.subtract(ids)
            }
            try await load(ids)
        }
        guard let resolved = infos[id] else { throw AppFailure("Steam 未返回 AppID \(id) 的资料 / No metadata for AppID \(id)") }
        let info = try resolved.get()
        if includeDLC {
            pendingDLC.formUnion(info.dlc.filter { !excluded.contains($0) && infos[$0] == nil })
        }
        return info
    }

    private func load(_ ids: [Int]) async throws {
        var batch: [Int: Result<AppInfo, Error>] = [:]
        var missing: [Int] = []
        for id in ids {
            try Task.checkCancellation()
            do {
                let info = try await publicInfo(id)
                guard info.id == id else { throw AppFailure("AppID 不匹配 / AppID mismatch") }
                batch[id] = .success(info)
                if info.depots.isEmpty && (info.sharedDepots ?? []).isEmpty { missing.append(id) }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                batch[id] = .failure(error)
                missing.append(id)
            }
        }
        do {
            let products = try await steam?(ids, missing) ?? []
            try Task.checkCancellation()
            for app in products where ids.contains(app.id) {
                guard let token = UInt64(app.accessToken), token > 0 else { continue }
                tokens[app.id] = String(token)
                guard missing.contains(app.id) else { continue }
                guard let json = app.productInfo,
                      let dict = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                      !dict.isEmpty else {
                    notices.append("Steam 未返回 AppID \(app.id) 的补充资料 / No additional Steam metadata for AppID \(app.id)")
                    continue
                }
                var full = AppInfo(id: app.id, dictionary: dict)
                if let original = try? batch[app.id]?.get() {
                    full.dlc = Array(Set(original.dlc + full.dlc)).sorted()
                    full.platforms.formUnion(original.platforms)
                    if original.name != "App \(app.id)" { full.name = original.name }
                    full.appType = full.appType ?? original.appType
                    full.declaresDepots = full.declaresDepots == true || original.declaresDepots == true
                    full.branches = full.branches ?? original.branches
                }
                batch[app.id] = .success(full)
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // A failed login should not delay every subsequent DLC with another retry.
            steam = nil
            notices.append("Steam 令牌查询失败，已保留公开资料 / Steam token lookup failed; kept public metadata: \(error.localizedDescription)")
        }
        infos.merge(batch) { first, _ in first }
    }

    public func addingTokens(to text: String, preserving existingIDs: Set<Int> = []) throws -> String {
        guard !tokens.isEmpty else { return text }
        let document = try LuaDocument.parse(text)
        let dlc = includeDLC ? document.dlcIDs.filter { !excluded.contains($0) } : []
        let lines = ([document.appID] + dlc).compactMap { id -> String? in
            guard !existingIDs.contains(id), document.tokens[id] == nil, let token = tokens[id] else { return nil }
            return "addtoken(\(id), \"\(token)\")"
        }
        guard !lines.isEmpty else { return text }
        return text + (text.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n") + "\n"
    }
}
