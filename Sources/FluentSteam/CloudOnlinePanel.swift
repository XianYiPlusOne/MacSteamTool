import SwiftUI
import FluentCore

struct CloudOnlinePanel: View {
    @EnvironmentObject var model: AppModel
    let provider: CloudProvider
    let engine: URL
    @ViewState<String> private var account = ""
    @ViewState<String> private var status = ""
    @ViewState<[CloudRemoteApp]> private var apps = []
    @ViewState<Bool> private var confirmProbe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(model.tr("在线存储验证与远端存档", "Online verification & remote saves")).font(.subheadline.bold())
            Text(model.tr("使用当前所选服务商已保存的凭证，不会保存表单或切换正在使用的存储后端。连接测试成功也不代表游戏进度已上传。", "Uses saved credentials for the selected provider. Does not save the form or switch the active backend. A successful connection test does not mean game saves have been uploaded.")).font(.caption).foregroundStyle(.secondary)
            Button(model.tr("测试上传、下载和清理…", "Test upload, download & cleanup…")) { confirmProbe = true }
            HStack {
                TextField(model.tr("Steam AccountID 或 SteamID64", "Steam AccountID or SteamID64"), text: $account).textFieldStyle(.roundedBorder)
                Button(model.tr("读取远端存档", "Read remote saves")) { listRemote() }.disabled(account.isEmpty)
            }
            Text(model.tr("远端清单包含文件和同步元数据；读取不会还原、覆盖或删除游戏存档。", "Remote counts include save data and sync metadata. Listing does not restore, overwrite or delete game saves.")).font(.caption).foregroundStyle(.secondary)
            ForEach(apps) { app in
                HStack {
                    Text("AppID \(app.appID)")
                    Spacer()
                    Text(model.tr("\(app.fileCount) 个文件", "\(app.fileCount) files"))
                    Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                }.font(.caption).textSelection(.enabled)
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
        }
        .disabled(model.busy || model.steamRunning)
        .task {
            if let accounts = try? Accounts.list(model.paths), let current = accounts.first(where: \.recent) ?? accounts.first {
                account = (try? CloudOnline.accountID(current.id)) ?? ""
            }
        }
        .confirmationDialog(model.tr("会在所选服务商的 0/0 测试目录上传 4 KB 随机数据，重新连接后下载校验，再删除测试文件。不读取或上传游戏存档；失败时会报告是否清理成功。", "Upload 4 KB of random test data in provider namespace 0/0, reconnect, download and verify, then remove the test object. No game saves are read or uploaded. Failures report cleanup status."), isPresented: $confirmProbe) {
            Button(model.tr("开始在线读写测试", "Run online read/write test")) { probe() }
        }
    }
    private func probe() {
        status = ""
        model.run(model.tr("验证在线存储", "Verify online storage"), cancellable: false) {
            guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
            let output = try await CloudEngine.run(["probe-provider", provider.rawValue], executable: engine, paths: model.paths, timeout: 300)
            let report = try CloudOnline.decodeLast(CloudConnectionTest.self, from: output)
            guard report.fullyVerified else { throw AppFailure("在线读写校验未全部通过 / Online verification was not fully successful") }
            status = model.tr("已验证：上传 → 重新连接 → 下载内容一致 → 测试文件已清理。\n尚未上传游戏存档，也未验收另一台设备。", "Verified: upload → reconnect → matching download → test object removed.\nNo game saves uploaded; a second physical device remains unverified.")
        }
    }
    private func listRemote() {
        apps = []; status = ""
        model.run(model.tr("读取远端存档", "Read remote saves")) {
            guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
            let id = try CloudOnline.accountID(account)
            let output = try await CloudEngine.run(["list-remote-apps", provider.rawValue, id], executable: engine, paths: model.paths)
            let inventory = try CloudOnline.decodeLast(CloudRemoteInventory.self, from: output)
            guard inventory.success else { throw AppFailure("远端清单读取失败 / Remote listing failed") }
            apps = inventory.apps
            status = model.tr("该账号的远端存档：\(apps.count) 款游戏。", "Remote saves for this account: \(apps.count) games.")
        }
    }
}
