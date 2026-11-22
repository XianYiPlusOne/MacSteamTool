import SwiftUI
import AppKit
import FluentCore

struct OfflineToolsPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var appID: Int
    var gameRoot: URL?
    var preview: (PatchPlan) -> Void
    @ViewState<URL?> private var steamless = nil
    @ViewState<URL?> private var goldberg = nil
    @ViewState<String> private var executable = ""
    @ViewState<String> private var account = "Fluent Player"
    @ViewState<Bool> private var overlay = true
    @ViewState<Bool> private var withAchievements = true
    @ViewState<Bool> private var withInventory = false
    @ViewState<String> private var webAPIKey = ""
    @ViewState<Bool> private var withImages = false
    @ViewState<OfflineInventory?> private var importedInventory = nil
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.tr("SteamStub 与离线启动", "SteamStub & offline launch")).font(.headline)
                Text(model.tr("先在上方选择目标 Windows 游戏。工具只生成待部署文件，检查预览后再备份写入。", "Choose the target Windows game above. Tools prepare files for review; deployment starts only from the backup preview.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Steamless").frame(width: 90, alignment: .leading)
                    Text(version(steamless, provider: "steamless")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.tr("下载官方工具", "Download official tool")) { download("steamless") }.disabled(model.busy)
                    Button(model.tr("项目说明 ↗", "Project ↗")) { model.openURL("https://github.com/atom0s/Steamless") }
                }
                HStack {
                    TextField(model.tr("目标游戏 .exe", "Target game .exe"), text: $executable).textFieldStyle(.roundedBorder)
                    Button(model.tr("选择…", "Choose…")) { let panel = NSOpenPanel(); panel.directoryURL = gameRoot; if panel.runModal() == .OK, let url = panel.url { executable = url.path } }
                    Button(model.tr("处理副本并预览", "Unpack copy & review"), action: unpack).disabled(model.busy || steamless == nil || appID == 0 || gameRoot == nil || executable.isEmpty)
                }
                Text(model.tr("支持 Steamless 的 SteamStub 变体；不支持 Denuvo。通过目标游戏的 NotProton 前缀运行独立助手，需要该前缀已经建立。", "Supports Steamless SteamStub variants; Denuvo is unsupported. Runs a separate helper inside the target game's existing NotProton prefix.")).font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Goldberg").frame(width: 90, alignment: .leading)
                    Text(version(goldberg, provider: "goldberg")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.tr("下载 / 更新", "Download / update")) { download("goldberg") }.disabled(model.busy)
                    Button(model.tr("项目说明 ↗", "Project ↗")) { model.openURL("https://github.com/Detanup01/gbe_fork") }
                }
                HStack {
                    TextField(model.tr("离线昵称", "Offline nickname"), text: $account).textFieldStyle(.roundedBorder)
                }
                Toggle(model.tr("显示游戏内成就弹窗", "Show in-game achievement notifications"), isOn: $overlay)
                Text(model.tr("弹窗需要游戏的成就定义。开启时使用 Goldberg 实验版覆盖层；遇到显示或启动问题时可关闭。", "Notifications require achievement definitions. Turn off the experimental Goldberg overlay if the game has display or startup issues.")).font(.caption).foregroundStyle(.secondary)
                Toggle(model.tr("获取成就与统计定义", "Fetch achievement and stat definitions"), isOn: $withAchievements)
                Toggle(model.tr("生成离线物品定义与初始库存", "Generate offline item definitions and initial inventory"), isOn: $withInventory)
                if withAchievements || withInventory {
                    SecureField(model.tr("可选 Steam Web API Key，仅本次使用", "Optional Steam Web API key, session only"), text: $webAPIKey).textFieldStyle(.roundedBorder)
                    Text(model.tr("Key 留空会跳过成就和库存查询，仍可部署。已手动导入的物品定义可离线使用。", "Leave the key blank to skip achievement and inventory lookups and continue deployment. Manually imported item definitions work offline.")).font(.caption).foregroundStyle(.secondary)
                    if withAchievements && !webAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Toggle(model.tr("同时下载成就图标", "Download achievement icons"), isOn: $withImages) }
                }
                if withInventory {
                    HStack {
                        Button(model.tr("导入物品定义 JSON…", "Import item definitions JSON…")) {
                            let p = NSOpenPanel(); p.allowedFileTypes = ["json"]
                            if p.runModal() == .OK, let url = p.url { do { importedInventory = try OfflineInventory.parse(FileStore.read(url)) } catch { model.fail(error) } }
                        }
                        if let importedInventory { Text("\(importedInventory.items.count) " + model.tr("项", "items")).font(.caption); Button(model.tr("清除导入", "Clear import")) { self.importedInventory = nil } }
                    }
                    Text(model.tr("用于 Goldberg 本地模拟器；不会写入 Steam 在线库存。填写 Key 后可从 Steam 获取物品定义。", "Used by the local Goldberg emulator. Does not write Steam inventory. A Web API key enables Steam item-definition lookups.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.tr("一键处理并部署预览", "Prepare complete offline launch")) { prepareGoldberg(combined: true) }.buttonStyle(.borderedProminent).disabled(model.busy || steamless == nil || goldberg == nil || appID == 0 || gameRoot == nil || executable.isEmpty)
                    Button(model.tr("仅生成 Goldberg 配置", "Prepare Goldberg only")) { prepareGoldberg() }.disabled(model.busy || goldberg == nil || appID == 0 || gameRoot == nil)
                }
                Text(model.tr("一键流程将 Steamless 输出与 Goldberg 配置合并为一次预览、备份和还原。", "The complete workflow combines Steamless and Goldberg into one preview, backup and restore.")).font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { reload() }.onChange(of: appID) { _, _ in importedInventory = nil; executable = "" }.onChange(of: gameRoot) { _, _ in importedInventory = nil; executable = "" }
    }
    private func version(_ folder: URL?, provider: String) -> String {
        guard let folder, let info = try? ToolPackage.load(folder, provider: provider) else { return model.tr("未下载", "Not downloaded") }; return info.version
    }
    private func reload() {
        func latest(_ provider: String) -> URL? {
            FileStore.files(model.paths.cache.appendingPathComponent("Tools/" + provider)).filter { (try? ToolPackage.load($0, provider: provider)) != nil }.sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }.first
        }
        steamless = latest("steamless"); goldberg = latest("goldberg")
    }
    private func download(_ provider: String) {
        model.run(model.tr("下载并校验工具包", "Download and verify tool package")) {
            var request = SteamEngineRequest("tool-download"); request.provider = provider; request.mirror = model.preferences.downloadMirror
            request.destination = model.paths.cache.appendingPathComponent("Tools/\(provider)/\(UUID().uuidString)").path
            if provider == "goldberg", let goldberg, let cached = try? ToolPackage.load(goldberg, provider: provider) {
                request.cachedGoldberg = .init(cached)
            }
            let result = try await SteamEngine.run(request, executable: model.engineExecutable)
            reload()
            if let warning = result.warnings?.first {
                model.log(warning)
                model.message = Message(title: model.tr("工具包版本", "Tool version"), detail: warning)
            }
        }
    }
    private func unpack() {
        guard let steamless, let gameRoot else { return }
        model.run(model.tr("处理 SteamStub 副本", "Unpack SteamStub copy")) {
            let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/SteamlessBridge/SteamlessBridge.exe")
            preview(try await OfflineTools.steamless(package: steamless, executable: URL(fileURLWithPath: executable), gameRoot: gameRoot, appID: appID, paths: model.paths, bridge: bridge, destination: model.paths.cache.appendingPathComponent("OfflineStages/\(UUID().uuidString)")))
        }
    }
    private func prepareGoldberg(combined: Bool = false) {
        guard let goldberg, let gameRoot else { return }
        let id = appID, dlcs = model.games.first(where: { $0.id == appID })?.dlcIDs ?? [], nickname = account, language = model.language
        let key = webAPIKey, wantInventory = withInventory, wantAchievements = withAchievements, images = withImages, imported = importedInventory, showOverlay = overlay
        model.run(model.tr("生成离线启动配置", "Prepare offline launch settings")) {
            let definitions = try await OfflineTools.definitions(appID: id, language: language, apiKey: key, achievements: wantAchievements, images: images, inventory: wantInventory, importedInventory: imported)
            let destination = model.paths.cache.appendingPathComponent("OfflineStages/\(UUID().uuidString)/Goldberg")
            let plan = try await Task.detached { try OfflineTools.goldberg(package: goldberg, gameRoot: gameRoot, appID: id, dlcs: dlcs, accountName: nickname, language: language, achievements: nil, inventory: definitions.inventory, schema: definitions.schema, overlay: showOverlay, destination: destination) }.value
            if combined {
                guard let steamless else { throw AppFailure("请先下载 Steamless / Download Steamless first") }
                let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/SteamlessBridge/SteamlessBridge.exe")
                let unpacked = try await OfflineTools.steamless(package: steamless, executable: URL(fileURLWithPath: executable), gameRoot: gameRoot, appID: id, paths: model.paths, bridge: bridge, destination: destination.deletingLastPathComponent().appendingPathComponent("Steamless"))
                preview(try OfflineTools.combined([unpacked, plan]))
            } else { preview(plan) }
        }
    }
}
