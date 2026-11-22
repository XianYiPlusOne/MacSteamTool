import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacSteamToolCore

struct OfflineToolsPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<[String: PatchLoadCheck]> private var loadChecks = [:]
    @ViewState<Int> private var appID = 0
    @ViewState<URL?> private var customRoot = nil
    @ViewState<PatchPlan?> private var plan = nil
    @ViewState<[PatchReceipt]> private var receipts = []
    @ViewState<PatchReceipt?> private var restoring = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(
                title: model.tr("离线工具与还原", "Offline tools & restore"),
                subtitle: model.tr(
                    "离线启动是实验性功能，开发者尚未进行实机测试。应用配置后，游戏仍可能无法离线启动。",
                    "Offline launch is experimental. The developer hasn’t tested it with a game yet, so your game may still fail to launch offline after you apply the settings."
                )
            ) { EmptyView() }
            Panel { PatchTargetPanel(appID: $appID, customRoot: $customRoot) }
            OfflineToolsPanel(appID: $appID, gameRoot: gameRoot) { value in plan = value }
            Panel {
                Text(model.tr("已部署记录", "Deployment history")).font(.headline)
                if receipts.isEmpty { Text(model.tr("尚未部署补丁", "No patches deployed")).foregroundStyle(.secondary) }
                ForEach(receipts) { receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) { Text("App \(receipt.appID) · \(receipt.source)"); Text(receipt.gameRoot).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            Spacer(); Text(receipt.date, style: .date).font(.caption)
                            Button(model.tr("检查补丁加载", "Check DLL loading")) { verifyLoading(receipt) }.disabled(receipt.restored || receipt.windowsTarget == nil || model.busy)
                            Button(receipt.restored ? model.tr("已还原", "Restored") : model.tr("还原", "Restore")) { restoring = receipt }.disabled(receipt.restored || model.busy || model.steamRunning)
                        }
                        if receipt.windowsTarget == nil { Text(model.tr("此记录未保存 Windows 运行目标；重新预览部署后才能校验加载。", "No Windows runtime identity in this record; preview and redeploy to enable load checks.")).font(.caption).foregroundStyle(.secondary) }
                        if let check = loadChecks[receipt.id] {
                            Text(loadTitle(check)).font(.caption.bold())
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            Text(model.tr("最近检查（非实时）：", "Last check (not live): ") + check.date.formatted(date: .numeric, time: .standard)).font(.caption)
                            if !check.loaded.isEmpty { Text(model.tr("已观察：", "Observed: ") + check.loaded.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                            if !check.missing.isEmpty { Text(model.tr("未观察：", "Not observed: ") + check.missing.joined(separator: ", ")).font(.caption).textSelection(.enabled) }
                        } else if !receipt.restored && receipt.windowsTarget != nil { Text(model.tr("已部署，尚未验证加载", "Deployed; loading not yet verified")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .onAppear { receipts = GamePatches.receipts(paths: model.paths) }
        .sheet(item: $plan) { value in
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(onClose: { plan = nil }) {
                    Text(model.tr("补丁部署预览", "Patch deployment preview")).font(.title2.bold())
                }
                Text(value.gameRoot.path).font(.caption).textSelection(.enabled)
                Text(model.tr("\(value.entries.count) 个文件，\(value.entries.filter(\.replacing).count) 个将被覆盖并备份", "\(value.entries.count) files; \(value.entries.filter(\.replacing).count) will be replaced and backed up"))
                if let target = value.windowsTarget { Text("Windows \(target.architecture.rawValue) · \(target.kind.rawValue)\n" + target.executable + "\n" + target.prefix).font(.caption).textSelection(.enabled) }
                if let registry = value.registry { Text(model.tr("还将备份并修改 Wine 注册表：", "Also back up and update Wine registry: ") + registry.url.path).font(.caption).foregroundStyle(.orange) }
                ScrollView { VStack(alignment: .leading) { ForEach(value.entries) { entry in HStack { Text(entry.replacing ? model.tr("替换", "Replace") : model.tr("新增", "Add")).foregroundStyle(entry.replacing ? .orange : .green).frame(width: 65); Text(entry.relative).font(.system(size: 11, design: .monospaced)); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(entry.data.count), countStyle: .file)).font(.caption) } } } }.frame(height: 320)
                HStack { Spacer(); Button(model.tr("取消", "Cancel")) { plan = nil }; Button(model.tr("备份并部署", "Back up & deploy")) { install(value) }.buttonStyle(.borderedProminent).disabled(model.busy || model.steamRunning) }
                if model.steamRunning { Text(model.tr("请先退出 Steam", "Quit Steam first")).foregroundStyle(.orange).font(.caption) }
            }.padding(25).frame(width: 760)
        }
        .confirmationDialog(model.tr("还原此补丁的全部修改？", "Restore all changes from this patch?"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button(model.tr("校验并还原", "Verify & restore")) { if let receipt = restoring { restore(receipt) }; restoring = nil }
        }
    }
    private var gameRoot: URL? { customRoot ?? model.games.first(where: { $0.id == appID })?.installed?.folder }
    private func verifyLoading(_ receipt: PatchReceipt) {
        loadChecks.removeValue(forKey: receipt.id)
        model.run(model.tr("读取 Windows 游戏模块", "Read Windows game modules")) {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/PatchProbe/PatchProbe.exe")
            loadChecks[receipt.id] = try await PatchLoadVerification.check(receipt, paths: model.paths, helper: helper)
        }
    }
    private func loadTitle(_ check: PatchLoadCheck) -> String {
        switch check.state {
        case .loaded: model.tr("已观察到全部补丁 DLL（不代表联机成功）", "All patch DLLs observed; multiplayer unverified")
        case .partial: model.tr("仅观察到部分补丁 DLL", "Some patch DLLs observed")
        case .notLoaded: model.tr("游戏正在运行，未观察到补丁 DLL", "Game running; patch DLLs not observed")
        case .notRunning: model.tr("未观察到所选游戏进程", "Selected game process not observed")
        case .inconclusive: model.tr("无法唯一确认加载", "Cannot uniquely verify loading")
        }
    }
    private func checkStopped(_ root: String) async throws {
        guard !model.steamRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
        let (_, output) = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "command="])
        let runners = model.paths.notProton.appendingPathComponent("runners").path + "/"
        guard !output.components(separatedBy: .newlines).contains(where: { $0.contains(runners) && $0.lowercased().contains("wine") }) else { throw AppFailure("NotProton Wine 工具仍在运行，请退出后重试 / NotProton Wine tools are still running; close them and retry") }
        guard !output.components(separatedBy: .newlines).contains(where: { $0.contains(root + "/") && $0.lowercased().contains(".exe") }) else { throw AppFailure("游戏仍在运行，请退出后重试 / Game is still running; close it and retry") }
    }
    private func install(_ value: PatchPlan) {
        plan = nil
        model.run(model.tr("备份并部署补丁", "Back up and deploy patch")) { try await checkStopped(value.gameRoot.path)
            if let target = value.windowsTarget { try await PatchLoadVerification.assertStopped(target: target, appID: value.appID, paths: model.paths) }
            let p = model.paths; _ = try await Task.detached { try GamePatches.install(value, paths: p) }.value; receipts = GamePatches.receipts(paths: p) }
    }
    private func restore(_ receipt: PatchReceipt) {
        model.run(model.tr("校验并还原补丁", "Verify and restore patch")) { try await checkStopped(receipt.gameRoot)
            if let target = receipt.windowsTarget { try await PatchLoadVerification.assertStopped(target: target, appID: receipt.appID, paths: model.paths) }
            let p = model.paths; try await Task.detached { try GamePatches.restore(receipt, paths: p) }.value; loadChecks.removeValue(forKey: receipt.id); receipts = GamePatches.receipts(paths: p) }
    }
}
