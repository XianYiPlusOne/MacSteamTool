import SwiftUI
import FluentCore

struct CloudDeleteSelection: Identifiable {
    let id = UUID()
    let account: String
    let app: Int
}

@MainActor final class CloudDeleteFlow: ObservableObject {
    @Published var preview: CloudDeletePreview?
    @Published var backup: CloudGameBackup?
    @Published var busy = false
    @Published var complete = false
    @Published var status = ""
    var operation: Task<Void, Never>?
    let service: CloudGameDeletion
    let provider: CloudProvider
    let account: String
    let app: Int
    init(service: CloudGameDeletion, provider: CloudProvider, account: String, app: Int) {
        self.service = service; self.provider = provider; self.account = account; self.app = app
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() } catch { status = error.localizedDescription }
        }
    }
    func load() {
        run {
            self.preview = nil; self.backup = nil; self.complete = false
            self.status = "读取完整目标清单… / Reading all targets…"
            self.preview = try await self.service.preview(provider: self.provider, account: self.account, app: self.app)
            self.status = "预览完成，源数据尚未更改 / Preview ready; source data is unchanged"
        }
    }
    func createBackup() {
        guard let preview, backup == nil, !complete else { return }
        run {
            self.status = "复制并逐文件校验备份… / Copying and verifying backup…"
            self.backup = try await self.service.backup(preview)
            self.status = "备份已完成并回读校验，尚未删除源数据 / Backup complete and verified; no source deleted"
        }
    }
    func deleteConfirmed() {
        guard let backup, !complete else { return }
        run {
            self.status = "核对备份与源数据，删除后重新读取… / Rechecking backup and sources, deleting and verifying…"
            try await self.service.delete(backup)
            self.complete = true
            self.status = "删除和回查完成，已校验备份保留 / Deletion verified; validated backup retained"
        }
    }
}

struct CloudGameDeleteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: CloudDeleteFlow
    @ViewState<Bool> private var confirm = false
    let onDeleted: () -> Void
    init(provider: CloudProvider, selection: CloudDeleteSelection, paths: AppPaths, engine: URL, fixture: Bool, onDeleted: @escaping () -> Void = {}) {
        let service = CloudGameDeletion(paths: paths, engine: engine, steamRunning: { !fixture && SteamProcesses.isRunning })
        _flow = StateObject(wrappedValue: CloudDeleteFlow(service: service, provider: provider, account: selection.account, app: selection.app))
        self.onDeleted = onDeleted
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.tr("按游戏管理云端存档", "Manage cloud saves by game")).font(.title2.bold())
            Text("\(flow.provider.title) · AccountID \(flow.account) · AppID \(String(flow.app))").font(.subheadline).textSelection(.enabled)
            Text(model.tr("只处理上述账号和游戏。预览包含同步副本、本地缓存及 Steam userdata；其他账号、游戏与原游戏安装目录保留。请关闭游戏和 Steam，并停止其他设备写入此云端。", "Only this account and game are included: sync copies, local caches and Steam userdata. Other accounts, games and installed game folders are retained. Close the game and Steam and stop writes from other devices.")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview = flow.preview {
                        Text(model.tr("\(preview.fileCount) 个文件 · ", "\(preview.fileCount) files · ") + ByteCountFormatter.string(fromByteCount: preview.totalBytes, countStyle: .file)).font(.headline)
                        ForEach(preview.local) { target in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(target.kind) · \(target.snapshot.files.count) files · \(ByteCountFormatter.string(fromByteCount: target.snapshot.bytes, countStyle: .file))").font(.caption.bold())
                                Text(target.path).font(.caption).textSelection(.enabled)
                            }
                        }
                        if !preview.remote.isEmpty {
                            Text(model.tr("云端对象", "Remote objects")).font(.subheadline.bold())
                            ForEach(preview.remote, id: \.path) { file in HStack { Text(file.path).textSelection(.enabled); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) }.font(.caption) }
                        }
                        Text(model.tr("独立备份目录：", "Separate backup directory: ") + preview.directory.path).font(.caption).textSelection(.enabled)
                        Text(model.tr("本地副本保存在 local-N/data，云端原始对象与路径/摘要记录保存在 remote。备份不会自动上传或覆盖存档。", "Local copies are in local-N/data; raw cloud objects and path/hash records are in remote. Backups are not automatically uploaded or restored.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if flow.busy { ProgressView().controlSize(.small) }
                    Text(flow.status).font(.caption).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(flow.complete ? model.tr("完成", "Done") : model.tr("关闭", "Close")) { if flow.complete { onDeleted() }; dismiss() }.disabled(flow.busy)
                if let preview = flow.preview {
                    Button(model.tr("打开备份目录", "Open backup folder")) { model.openFolder(preview.directory) }
                }
                Spacer()
                if !flow.complete {
                    Button(model.tr("重新预览", "Refresh preview")) { flow.load() }.disabled(flow.busy)
                    Button(model.tr("创建并校验备份", "Create verified backup")) { flow.createBackup() }.disabled(flow.busy || flow.preview == nil || flow.backup != nil || (flow.preview?.fileCount == 0 && flow.preview?.local.isEmpty != false))
                    Button(model.tr("删除已备份数据…", "Delete backed-up data…"), role: .destructive) { confirm = true }.disabled(flow.busy || flow.backup == nil)
                }
            }
        }.padding(24).frame(width: 780, height: 620)
        .task { flow.load() }
        .interactiveDismissDisabled(flow.busy)
        .confirmationDialog(model.tr("删除 AccountID \(flow.account) / AppID \(flow.app) 的已备份存档和缓存？", "Delete backed-up saves and caches for account \(flow.account), app \(flow.app)?"), isPresented: $confirm) {
            Button(model.tr("确认删除并回查", "Confirm deletion and verify"), role: .destructive) { flow.deleteConfirmed() }
        } message: { Text(model.tr("已经完成独立备份并校验。将重新核对源数据；云端部分失败会保留本地缓存与完整备份并报告。", "An independent backup has been verified. Sources will be rechecked; a partial remote failure retains local caches and the backup and is reported.")) }
    }
}

struct CloudLocalGameManagementPanel: View {
    @EnvironmentObject var model: AppModel
    let provider: CloudProvider
    let engine: URL
    @ViewState<String> private var account = ""
    @ViewState<String> private var app = ""
    @ViewState<CloudDeleteSelection?> private var selection = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(model.tr("按账号和游戏预览、备份或删除同步副本", "Preview, back up or delete synced saves by account and game")).font(.subheadline.bold())
            Text(model.tr("预览、备份或删除前，请先退出游戏和 Steam。", "Quit the game and Steam before previewing, backing up or deleting.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("AccountID / SteamID64", text: $account).textFieldStyle(.roundedBorder)
                TextField("AppID", text: $app).textFieldStyle(.roundedBorder)
                Menu(model.tr("选择游戏", "Choose game")) { ForEach(model.games) { game in Button("\(game.name) · \(game.id)") { app = String(game.id) } } }
                Button(model.tr("预览管理…", "Preview & manage…")) {
                    do { guard let app = TextUtil.validID(app) else { throw AppFailure("Invalid AppID") }; selection = try CloudDeleteSelection(account: CloudOnline.accountID(account), app: app) } catch { model.fail(error) }
                }.disabled(model.busy || model.steamRunning || TextUtil.validID(app) == nil || account.isEmpty)
            }
            Button(model.tr("打开云存档删除备份", "Open cloud-deletion backups")) { model.openFolder(CloudGameDeletion.backupRoot(model.paths)) }
        }
        .task { if let accounts = try? Accounts.list(model.paths), let current = accounts.first(where: \.recent) ?? accounts.first { account = current.id } }
        .sheet(item: $selection) { value in CloudGameDeleteSheet(provider: provider, selection: value, paths: model.paths, engine: engine, fixture: model.testing).environmentObject(model) }
    }
}
