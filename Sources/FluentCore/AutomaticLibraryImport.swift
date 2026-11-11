import Foundation

public struct AutomaticLibraryResult: Sendable {
    public var files: [ImportFile]
    public var warnings: [String]
    public var complete: Bool
    public var notes: [String] = []
}

/// Resolves content before any library writes. A successful download alone is not
/// evidence of completeness: every requested app and depot must be accounted for.
public enum AutomaticLibraryImport {
    public static func resolve(
        appID: Int, includeDLC: Bool, context: LibraryInstallContext = .init(),
        appInfo: (Int) async throws -> AppInfo,
        cachedKeys: () async throws -> [Int: String],
        refreshKeys: () async throws -> [Int: String],
        remote: () async throws -> [ImportFile],
        progress: (String) async -> Void = { _ in }
    ) async throws -> AutomaticLibraryResult {
        try Task.checkCancellation()
        guard TextUtil.validID(String(appID)) != nil else { throw AppFailure("无效的 AppID / Invalid AppID") }
        await progress("正在检查游戏内容… / Checking game content…")
        var requirements: LibraryRequirements?
        var failures: [String] = []
        do { requirements = try await LibraryRequirements.load(appID, includeDLC: includeDLC, context: context, appInfo: appInfo) }
        catch { try Task.checkCancellation(); if error is CancellationError { throw error }; failures.append("无法核实内容完整性 / Could not verify content: \(error.localizedDescription)") }

        var keys: [Int: String] = [:]
        if let requirements {
            do { keys = try await cachedKeys() }
            catch { try Task.checkCancellation(); if error is CancellationError { throw error } }
            var candidate = requirements.result(keys: keys)
            if candidate.complete { return candidate }

            await progress("正在更新入库数据… / Updating library data…")
            do {
                let refreshed = try await refreshKeys()
                // Retain cached keys that a temporarily smaller response omits.
                keys.merge(refreshed) { _, fresh in fresh }
            } catch { try Task.checkCancellation(); if error is CancellationError { throw error }; failures.append("更新密钥失败 / Key refresh failed: \(error.localizedDescription)") }
            candidate = requirements.result(keys: keys)
            if candidate.complete { return candidate }
        }

        try Task.checkCancellation()
        await progress("正在尝试备用来源补齐内容… / Trying another source to complete content…")
        do {
            let files = try await remote()
            try Task.checkCancellation()
            guard files.count == 1, let file = files.first, file.name.lowercased().hasSuffix(".lua"),
                  let text = String(data: file.data, encoding: .utf8) else {
                throw AppFailure("备用来源必须提供一份匹配的 Lua / Alternate source must provide one matching Lua")
            }
            let document = try LuaDocument.parse(text, suggestedID: appID)
            guard document.entries.first?.id == appID else { throw AppFailure("备用来源游戏不匹配 / Alternate source game mismatch") }
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
                if !result.complete { result.warnings += failures }
                return result
            }
            // Without metadata, preserve the remote candidate for explicit
            // review, but never label it complete or import it automatically.
            let scoped = includeDLC ? text : mainOnly(document)
            return AutomaticLibraryResult(files: [ImportFile(name: "\(appID).lua", data: Data(scoped.utf8))], warnings: failures + document.warnings, complete: false)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            failures.append("备用来源未能补齐 / Alternate source failed: \(error.localizedDescription)")
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
