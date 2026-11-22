import SwiftUI
import AppKit
import MacSteamToolCore

struct OfflineToolsPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var appID: Int
    var gameRoot: URL?
    var preview: (PatchPlan) -> Void
    @ViewState<URL?> private var goldberg = nil
    @ViewState<String> private var account = "Player"
    @ViewState<Bool> private var overlay = true
    @ViewState<Bool> private var withAchievements = true
    @ViewState<Bool> private var withInventory = false
    @ViewState<String> private var webAPIKey = ""
    @ViewState<Bool> private var withImages = false
    @ViewState<OfflineInventory?> private var importedInventory = nil
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.tr("离线启动配置", "Offline launch configuration")).font(.headline)
                Text(model.tr("先在上方选择目标 Windows 游戏。工具只生成待部署文件，检查预览后再备份写入。", "Choose the target Windows game above. Tools prepare files for review; deployment starts only from the backup preview.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Goldberg").frame(width: 90, alignment: .leading)
                    Text(version).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.tr("下载 / 更新", "Download / update")) { downloadGoldberg() }.disabled(model.busy)
                    Link(model.tr("项目说明", "Project"), destination: URL(string: "https://github.com/Detanup01/gbe_fork")!)
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
                Button(model.tr("仅生成 Goldberg 配置", "Prepare Goldberg only"), action: prepareGoldberg)
                    .buttonStyle(.borderedProminent).disabled(model.busy || goldberg == nil || appID == 0 || gameRoot == nil)
            }
        }.onAppear { reload() }.onChange(of: appID) { _, _ in importedInventory = nil }.onChange(of: gameRoot) { _, _ in importedInventory = nil }
    }
    private var version: String {
        guard let goldberg, let info = try? ToolPackage.load(goldberg, provider: "goldberg") else {
            return model.tr("未下载", "Not downloaded")
        }
        return info.version
    }
    private func reload() {
        let cache = model.paths.cache.appendingPathComponent("Tools/goldberg")
        goldberg = FileStore.files(cache).filter { (try? ToolPackage.load($0, provider: "goldberg")) != nil }
            .max { lhs, rhs in
                let first = try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate
                let second = try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate
                return (first ?? .distantPast) < (second ?? .distantPast)
            }
    }
    private func downloadGoldberg() {
        model.run(model.tr("下载并校验工具包", "Download and verify tool package")) {
            let destination = model.paths.cache.appendingPathComponent("Tools/goldberg/\(UUID().uuidString)")
            let cached = goldberg.flatMap { try? ToolPackage.load($0, provider: "goldberg") }
            let warning = try await ToolPackage.download(provider: "goldberg", to: destination,
                mirror: model.preferences.downloadMirror, cached: cached)
            reload()
            if let warning {
                model.log(warning)
                model.message = Message(title: model.tr("工具包版本", "Tool version"), detail: warning)
            }
        }
    }
    private func prepareGoldberg() {
        guard let goldberg, let gameRoot else { return }
        let id = appID, dlcs = model.games.first(where: { $0.id == appID })?.dlcIDs ?? [], nickname = account, language = model.language
        let key = webAPIKey, wantInventory = withInventory, wantAchievements = withAchievements, images = withImages, imported = importedInventory, showOverlay = overlay
        model.run(model.tr("生成离线启动配置", "Prepare offline launch settings")) {
            let definitions = try await OfflineTools.definitions(appID: id, language: language, apiKey: key, achievements: wantAchievements, images: images, inventory: wantInventory, importedInventory: imported)
            let destination = model.paths.cache.appendingPathComponent("OfflineStages/\(UUID().uuidString)/Goldberg")
            let plan = try await Task.detached { try OfflineTools.goldberg(package: goldberg, gameRoot: gameRoot, appID: id, dlcs: dlcs, accountName: nickname, language: language, achievements: nil, inventory: definitions.inventory, schema: definitions.schema, overlay: showOverlay, destination: destination) }.value
            preview(plan)
        }
    }
}
