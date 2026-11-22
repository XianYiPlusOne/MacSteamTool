import Foundation

public struct AutomaticLibraryResult: Sendable {
    public var files: [ImportFile]
    public var warnings: [String]
    public var complete: Bool
    public var skippedDLC: Set<Int> = []
    public var notes: [String] = []
    public var content: [LibraryContentReport] = []
}

/// Resolves content before any library writes. A successful download alone is not
/// evidence of completeness: every requested app and depot must be accounted for.
public enum AutomaticLibraryImport {
    public typealias RemoteSource = (name: String, fetch: () async throws -> [ImportFile])

    public static func resolve(
        appID: Int, includeDLC: Bool, excludingDLC: Set<Int> = [], skipUnavailableDLC: Bool = false, context: LibraryInstallContext = .init(),
        appInfo: (Int) async throws -> AppInfo,
        cachedKeys: () async throws -> [Int: String],
        steamCachedKeys: ((Set<Int>) async throws -> [Int: String])? = nil,
        refreshKeys: () async throws -> [Int: String],
        remote: @escaping () async throws -> [ImportFile],
        remoteFallback: (() async throws -> [ImportFile])? = nil,
        remoteFallbacks: [RemoteSource] = [],
        contentUpdate: ([LibraryContentReport]) async -> Void = { _ in },
        progress: (String) async -> Void = { _ in }
    ) async throws -> AutomaticLibraryResult {
        try Task.checkCancellation()
        guard TextUtil.validID(String(appID)) != nil else { throw AppFailure("无效的 AppID / Invalid AppID") }
        await progress("正在检查游戏内容… / Checking game content…")
        var requirements: LibraryRequirements?
        var failures: [String] = []
        do { requirements = try await LibraryRequirements.load(appID, includeDLC: includeDLC, context: context, excludingDLC: excludingDLC, appInfo: appInfo, progress: progress) }
        catch { try Task.checkCancellation(); if error is CancellationError { throw error }; failures.append("无法核实内容完整性 / Could not verify content: \(error.localizedDescription)"); await progress(failures.last!) }

        func report(_ result: AutomaticLibraryResult, stage: String) async {
            await contentUpdate(result.content)
            let depots = result.content.flatMap(\.depots)
            await progress("\(stage)：\(result.content.count) 个内容 · \(depots.filter(\.hasKey).count)/\(depots.count) 个 Depot 有密钥")
            for item in result.content where !item.missingDepots.isEmpty || !item.metadataKnown {
                await progress("\(item.isMain ? "主游戏" : "DLC") \(item.name) · AppID \(item.id)：" +
                    (item.metadataKnown ? "缺少 Depot 密钥 \(item.missingDepots.map(String.init).joined(separator: ", "))" : "内容资料待核实"))
            }
        }
        var keys: [Int: String] = [:]
        if let requirements {
            do { keys = try await cachedKeys() }
            catch { try Task.checkCancellation(); if error is CancellationError { throw error }; await progress("本地密钥缓存不可用：\(error.localizedDescription)") }
            var candidate = requirements.result(keys: keys)
            await report(candidate, stage: "本地缓存检查")
            if candidate.complete { return candidate }

            let missing = requirements.depotIDs.subtracting(keys.filter { TextUtil.validKey($0.value) }.keys)
            if let steamCachedKeys, !missing.isEmpty {
                await progress("正在检查 Steam 本机 Depot 缓存… / Checking Steam's local depot cache…")
                do {
                    let local = try await steamCachedKeys(missing)
                    try Task.checkCancellation()
                    for (id, key) in local where missing.contains(id) && TextUtil.validKey(key) {
                        keys[id] = key.lowercased()
                    }
                    candidate = requirements.result(keys: keys)
                    await report(candidate, stage: "Steam 本机 Depot 缓存 / Steam local depot cache")
                    if candidate.complete { return candidate }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    await progress("Steam 本机缓存不可用 / Steam local cache unavailable: \(error.localizedDescription)")
                }
            }

            await progress("正在更新入库数据… / Updating library data…")
            do {
                let refreshed = try await refreshKeys()
                // Retain cached keys that a temporarily smaller response omits.
                keys.merge(refreshed) { _, fresh in fresh }
            } catch { try Task.checkCancellation(); if error is CancellationError { throw error }; failures.append("更新密钥失败 / Key refresh failed: \(error.localizedDescription)"); await progress(failures.last!) }
            candidate = requirements.result(keys: keys)
            await report(candidate, stage: "刷新密钥后检查")
            if candidate.complete { return candidate }
        }

        var sources: [RemoteSource] = [("远程 ZIP / Remote ZIP", remote)]
        if let remoteFallback { sources.append(("GitHub", remoteFallback)) }
        var remoteResult: AutomaticLibraryResult?
        var remoteDocument: LuaDocument?
        for source in sources + remoteFallbacks {
            try Task.checkCancellation()
            await progress("正在尝试来源 / Trying source · \(source.name)")
            do {
                let files = try await source.fetch()
                try Task.checkCancellation()
                guard files.count == 1, let file = files.first, file.name.lowercased().hasSuffix(".lua"),
                      let text = String(data: file.data, encoding: .utf8) else {
                    throw AppFailure("备用来源必须提供一份匹配的 Lua / Alternate source must provide one matching Lua")
                }
                let document = try LuaDocument.parse(text, suggestedID: appID)
                guard document.entries.first?.id == appID else { throw AppFailure("备用来源游戏不匹配 / Alternate source game mismatch") }
                await progress("已解析 AppID \(appID) 的 Lua：\(document.dlcIDs.count) 个 DLC · \(document.depots.count) 个 Depot 密钥条目")
                var remoteKeys: [Int: String] = [:]
                for entry in document.depots {
                    if let old = remoteKeys[entry.id], old != entry.key { throw AppFailure("备用来源密钥冲突：Depot \(entry.id) / Conflicting remote keys") }
                    remoteKeys[entry.id] = entry.key
                }
                // Depot keys should agree across sources; never silently choose a
                // different key when combining complementary packages.
                let relevant = requirements.map { $0.depotIDs.union($0.requested) } ?? Set(remoteKeys.keys)
                for (id, key) in remoteKeys where relevant.contains(id) {
                    if let old = keys[id], old != key { throw AppFailure("来源之间的密钥冲突：Depot \(id) / Sources disagree on a depot key") }
                }
                keys.merge(remoteKeys) { old, _ in old }
                if let requirements {
                    var result = requirements.result(keys: keys, remote: document)
                    await report(result, stage: source.name)
                    if result.complete { return result }
                    if result.warnings == [LuaDocument.versionPinNotice], !requirements.depotIDs.isEmpty {
                        return result
                    }
                    result.warnings += failures
                    remoteResult = result
                    remoteDocument = document
                    continue
                }
                // Without metadata, keep the first valid package for explicit review.
                let scoped = includeDLC ? text : mainOnly(document)
                remoteResult = AutomaticLibraryResult(files: [ImportFile(name: "\(appID).lua", data: Data(scoped.utf8))], warnings: failures + document.warnings, complete: false)
                break
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let failure = "\(source.name)：\(error.localizedDescription)"
                failures.append(failure)
                await progress(failure)
            }
        }
        try Task.checkCancellation()
        if skipUnavailableDLC, includeDLC, let requirements, let main = requirements.apps.first {
            let reports = remoteResult?.content ?? requirements.report(keys: keys)
            let skipped = Set(reports.filter(\.isUnavailableOptionalDLC).map(\.id)).intersection(main.dlc)
            if !skipped.isEmpty {
                let known = Dictionary(requirements.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let scoped = try await LibraryRequirements.load(appID, includeDLC: true, context: context,
                    excludingDLC: excludingDLC.union(skipped), appInfo: { id in
                        if let info = known[id] { return info }
                        return try await appInfo(id)
                    }, progress: progress)
                var reduced = scoped.result(keys: keys, remote: remoteDocument)
                if reduced.complete || (reduced.warnings == [LuaDocument.versionPinNotice] && !scoped.depotIDs.isEmpty) {
                    reduced.skippedDLC = skipped
                    await report(reduced, stage: "跳过不可用的可选 DLC 后检查")
                    return reduced
                }
            }
        }
        if var result = remoteResult {
            result.warnings = Array(Set(result.warnings + failures)).sorted()
            return result
        }
        if let requirements {
            var candidate = requirements.result(keys: keys)
            if !requirements.depotIDs.isDisjoint(with: keys.keys) || requirements.depotIDs.isEmpty {
                candidate.warnings += failures
                candidate.complete = false
                return candidate
            }
            failures = candidate.warnings + failures
        }
        throw AppFailure((["入库未完成，未修改游戏库 / Import incomplete; library unchanged"] + failures).joined(separator: "\n"))
    }

    private static func mainOnly(_ doc: LuaDocument) -> String {
        var text = "addappid(\(doc.appID)) -- \(TextUtil.cleanLine(doc.name))\n"
        let depots = doc.depots.filter { $0.owner == doc.appID }
        for depot in depots { text += "addappid(\(depot.id), 1, \"\(depot.key!)\")\n" }
        if let token = doc.tokens[doc.appID] { text += "addtoken(\(doc.appID), \"\(token)\")\n" }
        for pin in doc.pins where depots.contains(where: { $0.id == pin.depot }) {
            text += "\(pin.active ? "" : "-- ")setManifestid(\(pin.depot), \"\(pin.manifest)\", 0)\n"
        }
        return text
    }
}
