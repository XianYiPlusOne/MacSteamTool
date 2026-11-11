import Foundation

struct LibraryRequirements {
    struct Content { var owner: Int; var depot: Depot }
    var appID: Int
    var context: LibraryInstallContext
    var apps: [AppInfo]
    var requested: [Int]
    var content: [Content]
    var issues: [String]
    var notes: [String]
    var depotIDs: Set<Int> { Set(content.map { $0.depot.id }) }

    static func load(_ id: Int, includeDLC: Bool, context: LibraryInstallContext, appInfo: (Int) async throws -> AppInfo) async throws -> Self {
        let main = try await appInfo(id)
        guard main.id == id else { throw AppFailure("游戏资料不匹配 / Game metadata mismatch") }
        var context = context
        if context.platform == .automatic {
            let primary = main.depots.filter {
                $0.dlc == nil && !main.dlc.contains($0.id) && manifest($0, branch: context.branch) != nil &&
                ($0.architecture == nil || $0.architecture == "" || $0.architecture == "all" || $0.architecture == context.architecture)
            }
            let native = primary.contains { matches($0.os, "macos") && (main.platforms.contains("macos") || values($0.os).contains("macos")) }
            let windows = primary.contains { matches($0.os, "windows") && (main.platforms.contains("windows") || values($0.os).contains("windows")) }
            let sharedOnly = main.depots.isEmpty && !(main.sharedDepots ?? []).isEmpty
            if native || (sharedOnly && main.platforms.contains("macos")) { context.platform = .macos }
            else if windows || (sharedOnly && main.platforms.contains("windows")) { context.platform = .windows }
            else { throw AppFailure("当前分支没有可核实的 macOS 或 Windows 游戏内容 / No verifiable macOS or Windows content for the selected branch") }
        }
        var result = Self(appID: id, context: context, apps: [main], requested: [id], content: [], issues: [], notes: [])
        if !main.platforms.contains(context.platform.rawValue) &&
            !main.depots.contains(where: { values($0.os).contains(context.platform.rawValue) && manifest($0, branch: context.branch) != nil }) {
            result.issues.append("无法核实所选运行平台的支持情况 / Selected runtime platform support is unverified")
        }
        var cache: [Int: AppInfo] = [id: main]
        var index = 0
        while index < result.apps.count {
            try Task.checkCancellation()
            let app = result.apps[index]; index += 1
            let all = app.depots + (app.sharedDepots ?? [])
            if all.isEmpty && app.declaresDepots != true && app.appType?.lowercased() != "dlc" {
                result.issues.append("AppID \(app.id) 内容资料不完整 / Content metadata incomplete")
            }
            for var depot in all where includeDLC || (depot.dlc == nil && !app.dlc.contains(depot.id)) {
                // A known platform mismatch is enough to exclude a shared depot
                // without fetching irrelevant Windows prerequisites on macOS.
                guard matches(depot.os, context.platform.rawValue) else { continue }
                if (app.sharedDepots ?? []).contains(where: { $0.id == depot.id }), depot.sourceApp == nil {
                    result.issues.append("Depot \(depot.id) 缺少共享来源资料 / Shared depot source is unknown")
                    continue
                }
                var source = app
                var visited: Set<Int> = [app.id]
                var resolved = true
                while let sourceID = depot.sourceApp {
                    guard visited.insert(sourceID).inserted else {
                        result.issues.append("Depot \(depot.id) 共享来源循环 / Shared depot source cycle"); resolved = false; break
                    }
                    do {
                        if cache[sourceID] == nil {
                            let fetched = try await appInfo(sourceID)
                            guard fetched.id == sourceID else { throw AppFailure("共享来源 AppID 不匹配 / Shared source AppID mismatch") }
                            cache[sourceID] = fetched
                        }
                        source = cache[sourceID]!
                        guard let original = (source.depots + (source.sharedDepots ?? [])).first(where: { $0.id == depot.id }) else {
                            throw AppFailure("共享来源没有该仓库 / Depot missing from shared source")
                        }
                        // The owner stays the requesting app/DLC; mounting
                        // restrictions and manifests come from the source app.
                        let ownerDLC = depot.dlc
                        depot = original
                        depot.dlc = ownerDLC ?? original.dlc
                    } catch {
                        try Task.checkCancellation(); if error is CancellationError { throw error }
                        result.issues.append("Depot \(depot.id) 共享内容无法核实 / Shared content unverified: \(error.localizedDescription)")
                        resolved = false; break
                    }
                }
                guard resolved, matches(depot.os, context.platform.rawValue) else { continue }
                if let arch = depot.architecture, !arch.isEmpty && arch != "all" {
                    if ["32", "64"].contains(arch) { if arch != context.architecture { continue } }
                    else { result.issues.append("Depot \(depot.id) 架构条件无法核实 / Architecture condition unverified") }
                }
                if let language = depot.language, !language.isEmpty && language.lowercased() != "all" {
                    if let selected = context.language { if !matches(language, selected) { continue } }
                    else { result.issues.append("Depot \(depot.id) 需要核实游戏内容语言 / Game content language must be verified") }
                }
                if let value = manifest(depot, branch: context.branch) { depot.manifest = value }
                else if depot.branchManifests?[context.branch] != nil {
                    result.issues.append("Depot \(depot.id) 当前分支清单无效 / Selected branch manifest is invalid")
                }
                else if depot.encryptedBranches?.contains(context.branch) == true {
                    result.issues.append("Depot \(depot.id) 当前分支清单受限，无法核实 / Selected branch manifest is restricted")
                } else if depot.branchManifests != nil, source.branches?.contains(context.branch) == true {
                    result.notes.append("Depot \(depot.id) 不属于当前分支的已发布内容 / No published content on selected branch")
                    continue
                } else {
                    result.issues.append("Depot \(depot.id) 当前分支内容无法核实 / Selected branch content unverified")
                }
                result.content.append(Content(owner: depot.dlc ?? app.id, depot: depot))
            }
            guard includeDLC else { continue }
            for child in app.dlc where !result.requested.contains(child) {
                guard result.requested.count < 2048 else { throw AppFailure("DLC 数量超出检查限制 / Too many DLC entries to verify") }
                result.requested.append(child)
                do {
                    let info = try await appInfo(child)
                    guard info.id == child else { throw AppFailure("DLC 资料不匹配 / DLC metadata mismatch") }
                    cache[child] = info; result.apps.append(info)
                } catch {
                    try Task.checkCancellation(); if error is CancellationError { throw error }
                    result.issues.append("DLC \(child) 无法核实内容 / Could not verify DLC: \(error.localizedDescription)")
                }
            }
        }
        if !result.content.contains(where: { $0.owner == id && (UInt64($0.depot.manifest) ?? 0) > 0 }) {
            result.issues.append("当前平台与分支没有可核实的主游戏内容 / No verified base game content for the selected platform and branch")
        }
        result.notes.insert("检查范围 / Content scope: \(context.platform.rawValue) · \(context.architecture)-bit · \(context.branch)", at: 0)
        return result
    }

    static func values(_ text: String) -> Set<String> {
        Set(text.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    static func matches(_ filter: String, _ target: String) -> Bool {
        let list = values(filter)
        return list.isEmpty || list.contains("all") || list.contains(target.lowercased())
    }
    static func manifest(_ depot: Depot, branch: String) -> String? {
        let value = depot.branchManifests?[branch] ?? (branch == "public" ? depot.manifest : nil)
        guard let value, (UInt64(value) ?? 0) > 0 else { return nil }
        return value
    }

    func result(keys: [Int: String], remote: LuaDocument? = nil) -> AutomaticLibraryResult {
        let validKeys = keys.filter { TextUtil.validKey($0.value) }
        let missing = depotIDs.subtracting(validKeys.keys).sorted()
        var warnings = issues + missing.map { "Depot \($0) 缺少密钥 / Missing depot key" }
        var text = "-- Fluent Steam Mac / automatic library import\n-- \(context.platform.rawValue), \(context.architecture)-bit, branch: \(TextUtil.cleanLine(context.branch))\n"
        var writtenDepots = Set<Int>()
        for id in requested {
            let info = apps.first { $0.id == id }
            guard info != nil || remote?.entries.contains(where: { $0.id == id && $0.key == nil }) == true else { continue }
            text += "\naddappid(\(id)) -- \(TextUtil.cleanLine(info?.name ?? "DLC \(id)"))\n"
            if let key = validKeys[id] { text += "addappid(\(id), 1, \"\(key)\")\n"; writtenDepots.insert(id) }
            var owned = Set(content.filter { $0.owner == id }.map { $0.depot.id })
            if info == nil { owned.formUnion(remote?.depots.filter { $0.owner == id }.map(\.id) ?? []) }
            for depot in owned.sorted() {
                if let key = validKeys[depot] { text += "addappid(\(depot), 1, \"\(key)\")\n"; writtenDepots.insert(depot) }
            }
            if let token = remote?.tokens[id] { text += "addtoken(\(id), \"\(token)\")\n" }
        }
        for pin in remote?.pins ?? [] where writtenDepots.contains(pin.depot) {
            text += "\(pin.active ? "" : "-- ")setManifestid(\(pin.depot), \"\(pin.manifest)\", 0)\n"
        }
        // Parse the scoped document to report only retained tokens and pins.
        warnings += (try? LuaDocument.parse(text, suggestedID: appID).warnings) ?? []
        warnings += remote?.warnings.filter { $0.hasPrefix("未转换语句") } ?? []
        warnings = Array(Set(warnings)).sorted()
        return AutomaticLibraryResult(files: [ImportFile(name: "\(appID).lua", data: Data(text.utf8))], warnings: warnings, complete: warnings.isEmpty, notes: notes)
    }
}
