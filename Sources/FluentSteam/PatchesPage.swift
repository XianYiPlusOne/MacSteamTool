import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FluentCore

struct PatchesPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var query = ""
    @ViewState<[OnlineFixResult]> private var results = []
    @ViewState<OnlineFixDetail?> private var detail = nil
    @ViewState<String> private var archive = ""
    @ViewState<String> private var password = "online-fix.me"
    @ViewState<String> private var extracted = ""
    @ViewState<String> private var payload = ""
    @ViewState<String> private var gameExecutable = ""
    @ViewState<String> private var overrides = ""
    @ViewState<String> private var runtimeKind = "notProton"
    @ViewState<String> private var bottlePath = ""
    @ViewState<String> private var crossOverPath = "/Applications/CrossOver.app"
    @ViewState<[String: PatchLoadCheck]> private var loadChecks = [:]
    @ViewState<Bool> private var configureOverrides = false
    @ViewState<Int> private var appID = 0
    @ViewState<URL?> private var customRoot = nil
    @ViewState<PatchPlan?> private var plan = nil
    @ViewState<[PatchReceipt]> private var receipts = []
    @ViewState<PatchReceipt?> private var restoring = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: model.tr("联机补丁", "Online patches"), subtitle: model.tr("仅支持 NotProton / CrossOver 中的 Windows x86 / x64 游戏；原生 Mac 游戏不支持。", "Supports Windows x86/x64 games in NotProton / CrossOver only. Native Mac games are unsupported.")) { Button(model.tr("下载目录", "Downloads")) { model.openFolder(model.paths.data.appendingPathComponent("Downloads")) } }
            OnlineFixModePanel()
            Panel {
                HStack { TextField(model.tr("英文游戏名称", "English game title"), text: $query).textFieldStyle(.roundedBorder).onSubmit(search); Button(model.tr("搜索", "Search"), action: search).disabled(model.busy || query.count < 2); Button(model.tr("打开原站", "Open website")) { model.openURL("https://online-fix.me/") } }
                ForEach(results) { result in
                    HStack { VStack(alignment: .leading) { Text(result.title); Text(result.version).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(model.tr("详情与下载", "Details & downloads")) { load(result) }.disabled(model.busy); Button(model.tr("原页面", "Source")) { model.openURL(result.url) } }
                }
            }
            if let detail {
                Panel {
                    Text(detail.title).font(.headline)
                    DisclosureGroup(model.tr("原站使用说明", "Source instructions")) { Text(detail.instructions).font(.caption).textSelection(.enabled) }
                    ForEach(detail.files) { file in HStack { VStack(alignment: .leading) { Text(file.name); Text(file.info).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(model.tr("下载", "Download")) { download(file) }.disabled(model.busy) } }
                    if detail.files.isEmpty { Text(model.tr("没有找到直链补丁文件，可打开原页面检查。", "No direct patch archives were found. Check the source page.")).foregroundStyle(.secondary) }
                }
            }
            Panel {
                Text(model.tr("部署本地补丁", "Deploy local patch")).font(.headline)
                HStack { TextField(model.tr("压缩包路径", "Archive path"), text: $archive).textFieldStyle(.roundedBorder); Button(model.tr("选择压缩包…", "Choose archive…")) { let panel = NSOpenPanel(); panel.allowedContentTypes = ["zip", "rar", "7z"].compactMap { UTType(filenameExtension: $0) }; if panel.runModal() == .OK, let url = panel.url { archive = url.path } } }
                HStack { SecureField(model.tr("解压密码（无密码留空）", "Archive password (empty if none)"), text: $password).textFieldStyle(.roundedBorder); Button(model.tr("解压并检查", "Extract & inspect"), action: extract).disabled(model.busy || archive.isEmpty) }
                HStack { TextField(model.tr("实际补丁文件所在目录", "Folder containing the patch files"), text: $payload).textFieldStyle(.roundedBorder); Button(model.tr("选择目录…", "Choose folder…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if !extracted.isEmpty { panel.directoryURL = URL(fileURLWithPath: extracted) }; if panel.runModal() == .OK, let url = panel.url { payload = url.path } } }
                Text(model.tr("补丁中的相对目录必须与游戏目录对应；若压缩包多包一层文件夹，请选择里面一层。", "Patch paths must match the game directory. If the archive has a wrapper folder, select the inner folder.")).font(.caption).foregroundStyle(.secondary)
                PatchTargetPanel(appID: $appID, customRoot: $customRoot)
                HStack {
                    TextField(model.tr("必须选择实际 Windows 游戏 .exe", "Required: actual Windows game .exe"), text: $gameExecutable).textFieldStyle(.roundedBorder)
                    Button(model.tr("选择程序…", "Choose executable…")) {
                        let panel = NSOpenPanel(); panel.directoryURL = gameRoot
                        if panel.runModal() == .OK, let url = panel.url { gameExecutable = url.path }
                    }
                }
                Picker(model.tr("Windows 运行环境", "Windows runtime"), selection: $runtimeKind) {
                    Text("NotProton").tag("notProton"); Text("CrossOver").tag("crossOver")
                }
                if runtimeKind == "crossOver" {
                    HStack { TextField("CrossOver.app", text: $crossOverPath).textFieldStyle(.roundedBorder); Button(model.tr("选择 CrossOver…", "Choose CrossOver…")) { let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { crossOverPath = url.path } } }
                    HStack { TextField(model.tr("该游戏所在的 CrossOver 容器目录", "CrossOver bottle containing this game"), text: $bottlePath).textFieldStyle(.roundedBorder); Button(model.tr("选择容器…", "Choose bottle…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { bottlePath = url.path } } }
                }
                Text(model.tr("预览会校验程序格式、补丁架构和已初始化的 Windows 容器；不匹配时拒绝部署。部署后需自行启动游戏，再从记录中检查 DLL 是否实际加载。", "Preview validates the executable, patch architecture and initialized Windows bottle. Launch the game yourself after deployment, then check actual DLL loading from its record.")).font(.caption).foregroundStyle(.secondary)
                Toggle(model.tr("为此游戏配置 Wine DLL 覆盖", "Configure Wine DLL overrides for this game"), isOn: $configureOverrides)
                if configureOverrides {
                    TextField(model.tr("DLL 名称，用逗号分隔，如 version,winmm；留空自动识别", "DLL names, comma-separated, e.g. version,winmm; empty to detect"), text: $overrides).textFieldStyle(.roundedBorder)
                    Text(model.tr("按程序文件名设置 native,builtin；同一容器内同名程序共享此覆盖。将 user.reg 与补丁一起备份；请先退出该容器的全部 Windows 程序。", "Sets native,builtin by executable filename; same-named programs in this bottle share it. Backs up user.reg with the patch. Close all Windows programs in this bottle first.")).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.tr("预览将修改的文件", "Preview file changes"), action: preview).buttonStyle(.borderedProminent).disabled(model.busy || payload.isEmpty || appID == 0 || gameRoot == nil || gameExecutable.isEmpty || (runtimeKind == "crossOver" && (bottlePath.isEmpty || crossOverPath.isEmpty)))
                Text(model.tr("安装和还原要求退出 Steam。每个被覆盖文件都有校验备份；还原前检查文件是否已被游戏更新或其他工具修改。", "Quit Steam before installing or restoring. Replaced files are backed up and verified; restore checks for changes made by game updates or other tools.")).font(.caption).foregroundStyle(.secondary)
            }
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
                Text(model.tr("补丁部署预览", "Patch deployment preview")).font(.title2.bold())
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
    private func search() { model.run(model.tr("搜索 OnlineFix", "Search OnlineFix")) { var request = SteamEngineRequest("onlinefix-search"); request.query = query; results = try await SteamEngine.run(request, executable: model.engineExecutable).fixes ?? [] } }
    private func load(_ item: OnlineFixResult) { model.run(model.tr("获取补丁详情", "Load patch details")) { var request = SteamEngineRequest("onlinefix-detail"); request.url = item.url; detail = try await SteamEngine.run(request, executable: model.engineExecutable).fixDetail } }
    private func download(_ file: OnlineFixFile) {
        model.run(model.tr("下载联机补丁", "Download online patch")) {
            var request = SteamEngineRequest("onlinefix-download"); request.url = file.url; request.referer = file.directory
            let filename = URL(fileURLWithPath: file.name).lastPathComponent
            request.destination = model.paths.data.appendingPathComponent("Downloads/\(UUID().uuidString.prefix(8))-\(filename)").path
            archive = try await SteamEngine.run(request, executable: model.engineExecutable).path ?? ""
        }
    }
    private func extract() {
        model.run(model.tr("解压并验证补丁", "Extract and validate patch")) {
            var request = SteamEngineRequest("patch-extract"); request.archive = archive; request.password = password
            request.destination = model.paths.cache.appendingPathComponent("Patches/\(UUID().uuidString)").path
            extracted = try await SteamEngine.run(request, executable: model.engineExecutable).path ?? ""; payload = extracted
            if !extracted.isEmpty { model.openFolder(URL(fileURLWithPath: extracted)) }
        }
    }
    private func preview() {
        guard let gameRoot else { return }
        model.run(model.tr("读取补丁部署计划", "Read patch deployment plan")) {
            let package = URL(fileURLWithPath: payload), root = gameRoot, id = appID
            let withOverrides = configureOverrides, exe = gameExecutable, names = overrides.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init), paths = model.paths
            let bottle = runtimeKind == "crossOver" ? URL(fileURLWithPath: bottlePath) : nil, crossOver = runtimeKind == "crossOver" ? URL(fileURLWithPath: crossOverPath) : nil
            plan = nil
            plan = try await Task.detached {
                let value = try GamePatches.onlinePlan(package: package, gameRoot: root, appID: id, executable: URL(fileURLWithPath: exe), paths: paths, bottle: bottle, crossOverApp: crossOver)
                if withOverrides {
                    return try GamePatches.addingOverrides(to: value, executable: URL(fileURLWithPath: exe), libraries: names.isEmpty ? WineOverrides.suggested(value) : names, paths: paths)
                }
                return value
            }.value
        }
    }
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
