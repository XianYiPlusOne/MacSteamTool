import SwiftUI
import FluentCore

extension AppModel {
    func repairAuthorizedContent() {
        guard !busy, let session = pendingImport ?? pendingAuthorizedRepair,
              session.automatic, let document = session.plan.documents.first else { return }
        let missing = session.verificationDepots.union(AuthorizedContentRepair.missingDepots(in: session.plan.warnings))
        guard !missing.isEmpty else { return }
        let credential: SteamCredential?
        do { credential = authorizedRepairFetch == nil ? try SteamKeychain.load() : nil }
        catch { fail(error); return }
        if credential == nil && authorizedRepairFetch == nil {
            pendingAuthorizedRepair = session; pendingImport = nil; page = .accounts
            message = Message(title: tr("需要 Steam 账号授权", "Steam account required"), detail: tr("请登录拥有该游戏的账号，然后点击“继续核验内容”。", "Sign in with the account that owns this game, then continue the content repair."))
            return
        }
        pendingAuthorizedRepair = session
        run(tr("账号授权补齐内容", "Repair authorized content"), logCompletion: false) {
            let id = document.appID
            let context = try LibraryInstallContext.read(appID: id, paths: self.paths)
            let response: SteamEngineResponse
            if let fetch = self.authorizedRepairFetch { response = try await fetch(id, missing, session.includeDLC) }
            else {
                guard !self.testing, let credential else { throw AppFailure("隔离环境不连接真实账号 / Fixtures cannot access real accounts") }
                var request = SteamEngineRequest("extract", credential: credential, appID: id)
                request.includeDLC = session.includeDLC; request.depotIDs = missing.sorted()
                response = try await SteamEngine.run(request, executable: self.engineExecutable)
            }
            try Task.checkCancellation()
            let repaired = try AuthorizedContentRepair.prepare(document: document, missing: missing, response: response)
            let merged = try LuaDocument.parse(String(decoding: repaired.data, as: UTF8.self), suggestedID: id)
            var keys: [Int: String] = [:]
            for entry in merged.depots { keys[entry.id] = entry.key }
            let metadata = self.generationMetadata(includeDLC: session.includeDLC, excludingDLC: session.excludedDLC)
            let check = try await LibraryContentChecker.check(appID: id, includeDLC: session.includeDLC,
                excludingDLC: session.excludedDLC, context: context, keys: keys, appInfo: { try await metadata.appInfo($0) })
            guard try LibraryInstallContext.read(appID: id, paths: self.paths) == context else {
                throw AppFailure("运行设置已变化，请重新检查 / Runtime settings changed; retry the check")
            }
            var plan = try self.service.plan([repaired])
            plan.warnings += await metadata.notices
            plan.warnings = Array(Set(plan.warnings + check.issues + check.missingDepotIDs.map { "Depot \($0) 缺少密钥 / Missing depot key" })).sorted()
            self.pendingImport = ImportSession(plan: plan, automatic: true, complete: check.complete,
                notes: session.notes + [self.tr("已取得 Steam 授权内容：", "Authorized Steam content received: ") + missing.sorted().map(String.init).joined(separator: ", "),
                    self.tr("尚未写入；导入时备份。完成后仍需下载和启动验证。", "Not written yet; import creates a backup. Download and launch verification are still required.")],
                includeDLC: session.includeDLC, excludedDLC: session.excludedDLC,
                checkLog: session.checkLog + [self.tr("账号授权补齐后重新检查完成", "Authorized content recheck completed")] + plan.warnings, content: check.content, installContext: context)
            self.pendingAuthorizedRepair = nil
            self.log(self.tr("授权补齐结果已检查，等待导入", "Authorized repair checked; ready to import"))
        }
    }
}
