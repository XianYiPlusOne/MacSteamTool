import SwiftUI
import AppKit
import MacSteamToolCore

extension AppModel {
    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1 }
    func checkForUpdates(silent: Bool = false) async {
        let text = preferences.updateFeed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let feed = AppUpdates.feedURL(text) else {
            if !silent { updateStatus = tr("请配置本移植版的 HTTPS 签名更新源，或导入本地更新包。", "Set this port's HTTPS signed feed, or import a local update.") }; return
        }
        do {
            if let (signed, release) = try await AppUpdates.check(feed: feed, publicKey: AppUpdates.publicKey(), currentBuild: currentBuild) {
                availableUpdate = signed; updateStatus = tr("发现更新：", "Update available: ") + release.version + " · build \(release.build)\n" + release.notes
                if silent { log(updateStatus) }
            } else { availableUpdate = nil; updateStatus = tr("当前已是此更新源的最新版本。", "Up to date for this feed.") }
        } catch { updateStatus = error.localizedDescription; if !silent { fail(error) } }
    }
    func prepareUpdate(archive: URL? = nil) {
        guard let signed = availableUpdate else { return }
        run(tr("验证并准备更新", "Verify and prepare update")) { [self] in
            preparedUpdate = try await AppUpdates.prepare(signed, publicKey: AppUpdates.publicKey(), archive: archive, staging: paths.data.appendingPathComponent("Updates"), currentBuild: currentBuild, mirror: preferences.downloadMirror)
            updateStatus = tr("更新已验证，点击安装会重启 MacSteamTool。Steam 和游戏继续运行。", "Update verified. Installing restarts MacSteamTool; Steam and games keep running.")
        }
    }
    func installUpdate() {
        guard let prepared = preparedUpdate else { return }
        run(tr("安装应用更新", "Install application update"), cancellable: false) { [self] in
            let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            let hash = try await Task.detached { (try AppUpdates.treeHash(prepared.application), try AppUpdates.treeHash(target)) }.value
            let plan = UpdateInstallPlan(source: prepared.application, target: target, expectedSource: hash.0, expectedTarget: hash.1, parentPID: ProcessInfo.processInfo.processIdentifier, build: prepared.release.build)
            let helper = prepared.folder.appendingPathComponent("MacSteamToolUpdater"), planURL = prepared.folder.appendingPathComponent("install.json")
            if FileStore.fm.fileExists(atPath: helper.path) { try FileStore.fm.removeItem(at: helper) }
            try FileStore.fm.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MacSteamToolUpdater"), to: helper)
            try FileStore.json(plan, to: planURL)
            let process = Process(); process.executableURL = helper; process.arguments = [planURL.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
            NSApp.terminate(nil)
        }
    }
}
struct UpdatePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel {
            Text(model.tr("应用更新", "Application updates")).font(.headline)
            TextField(model.tr("HTTPS 签名更新源（可用 {arch} 代表当前架构）", "HTTPS signed feed ({arch} selects the current architecture)"), text: Binding(get: { model.preferences.updateFeed ?? "" }, set: { model.preferences.updateFeed = $0 })).textFieldStyle(.roundedBorder)
            Toggle(model.tr("启动时自动检查更新", "Check for updates on launch"), isOn: Binding(get: { model.preferences.automaticallyCheckUpdates == true }, set: { model.preferences.automaticallyCheckUpdates = $0 }))
            HStack {
                Button(model.tr("检查更新", "Check now")) { model.run(model.tr("检查更新", "Check updates")) { await model.checkForUpdates() } }
                Button(model.tr("导入本地签名更新…", "Import signed update…")) { importLocal() }
                if model.availableUpdate != nil { Button(model.tr("下载并验证", "Download and verify")) { model.prepareUpdate() } }
                if model.preparedUpdate != nil { Button(model.tr("安装并重启应用", "Install and restart app")) { model.installUpdate() }.buttonStyle(.borderedProminent) }
            }.disabled(model.busy)
            Text(model.tr("仅接受此移植版公钥签名的更新。安装前检查内容与应用签名，并保留上一版本，可在 Finder 中恢复。", "Accepts updates signed by this port's public key. Verifies contents and code signatures, and retains the previous application for Finder recovery.")).font(.caption).foregroundStyle(.secondary)
            if !model.updateStatus.isEmpty { ReleaseNotes(markdown: model.updateStatus) }
        }
    }
    private func importLocal() {
        let p = NSOpenPanel(); p.message = model.tr("选择签名 release.json", "Select the signed release.json"); p.allowedFileTypes = ["json"]
        guard p.runModal() == .OK, let feed = p.url else { return }
        model.run(model.tr("读取本地更新", "Read local update")) {
            guard let (signed, _) = try await AppUpdates.check(feed: feed, publicKey: AppUpdates.publicKey(), currentBuild: model.currentBuild, allowFile: true) else { model.updateStatus = model.tr("更新版本不高于当前版本。", "The update is not newer than this version."); return }
            model.availableUpdate = signed
            let zip = NSOpenPanel(); zip.message = model.tr("选择对应 ZIP 更新包", "Select the matching ZIP archive"); zip.allowedFileTypes = ["zip"]
            guard zip.runModal() == .OK, let archive = zip.url else { return }
            model.preparedUpdate = try await AppUpdates.prepare(signed, publicKey: AppUpdates.publicKey(), archive: archive, staging: model.paths.data.appendingPathComponent("Updates"), currentBuild: model.currentBuild)
            model.updateStatus = model.tr("本地更新已验证，可以安装。", "Local update verified and ready to install.") + (model.preparedUpdate.map { "\n" + $0.release.notes } ?? "")
        }
    }
}
