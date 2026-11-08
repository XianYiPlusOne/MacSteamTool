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
    @ViewState<Bool> private var lan = false
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
                    Toggle(model.tr("允许局域网", "Allow LAN"), isOn: $lan)
                    Toggle(model.tr("读取成就定义", "Read achievement definitions"), isOn: $withAchievements)
                }
                Text(model.tr("替换匹配架构的 Steam API，生成 AppID / DLC / 语言配置；模拟器存档使用游戏目录下独立的 FluentOfflineSaves 文件夹。读取成就定义可使用运行中的 Steam，或填写 Web API Key。", "Replace the matching Steam API and generate AppID, DLC and language settings. Emulator saves use a separate FluentOfflineSaves folder in the game directory. Read achievement definitions from running Steam, or supply a Web API key.")).font(.caption).foregroundStyle(.secondary)
                Toggle(model.tr("生成离线物品定义与初始库存", "Generate offline item definitions and initial inventory"), isOn: $withInventory)
                if withAchievements || withInventory {
                    SecureField(model.tr("可选 Steam Web API Key，仅本次使用", "Optional Steam Web API key, session only"), text: $webAPIKey).textFieldStyle(.roundedBorder)
                    if withAchievements && !webAPIKey.isEmpty { Toggle(model.tr("同时下载成就图标", "Download achievement icons"), isOn: $withImages) }
                }
                if withInventory {
                    HStack {
                        Button(model.tr("导入物品定义 JSON…", "Import item definitions JSON…")) {
                            let p = NSOpenPanel(); p.allowedFileTypes = ["json"]
                            if p.runModal() == .OK, let url = p.url { do { importedInventory = try OfflineInventory.parse(FileStore.read(url)) } catch { model.fail(error) } }
                        }
                        if let importedInventory { Text("\(importedInventory.items.count) " + model.tr("项", "items")).font(.caption); Button(model.tr("清除导入", "Clear import")) { self.importedInventory = nil } }
                    }
                    Text(model.tr("用于 Goldberg 本地模拟器；不会写入 Steam 在线库存。未导入时从 Steam 获取公开定义。", "Used by the local Goldberg emulator. Does not write Steam inventory. Fetches public definitions when no file is imported.")).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.tr("生成 Goldberg 配置并预览", "Prepare Goldberg & review"), action: prepareGoldberg).buttonStyle(.borderedProminent).disabled(model.busy || goldberg == nil || appID == 0 || gameRoot == nil)
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
            _ = try await SteamEngine.run(request, executable: model.engineExecutable); reload()
        }
    }
    private func unpack() {
        guard let steamless, let gameRoot else { return }
        model.run(model.tr("处理 SteamStub 副本", "Unpack SteamStub copy")) {
            let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/SteamlessBridge/SteamlessBridge.exe")
            preview(try await OfflineTools.steamless(package: steamless, executable: URL(fileURLWithPath: executable), gameRoot: gameRoot, appID: appID, paths: model.paths, bridge: bridge, destination: model.paths.cache.appendingPathComponent("OfflineStages/\(UUID().uuidString)")))
        }
    }
    private func prepareGoldberg() {
        guard let goldberg, let gameRoot else { return }
        let id = appID, dlcs = model.games.first(where: { $0.id == appID })?.dlcIDs ?? [], nickname = account, language = model.language, network = lan
        let key = webAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), wantInventory = withInventory, wantAchievements = withAchievements, images = withImages, imported = importedInventory
        model.run(model.tr("生成离线启动配置", "Prepare offline launch settings")) {
            let inventory: OfflineInventory?
            if wantInventory {
                if let imported { inventory = imported }
                else { inventory = try await OfflineInventory.fetch(appID: id, apiKey: key) }
            } else { inventory = nil }
            var definitions: [Achievement]?
            var schema: OfflineSchema?
            if wantAchievements && !key.isEmpty {
                schema = try await OfflineSchema.fetch(appID: id, apiKey: key, language: language, withImages: images)
            } else if wantAchievements {
                guard model.steamRunning else { throw AppFailure("读取成就定义需要 Steam 正在运行；也可取消该选项，仅生成离线配置 / Steam must be running to read achievement definitions; uncheck this option to generate offline configuration only") }
                let request = AchievementRequest(appID: id, library: model.paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib").path)
                definitions = try await AchievementWorker.run(request, executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluentSteamWorker")).achievements
            }
            let achievements = definitions, offlineSchema = schema
            let destination = model.paths.cache.appendingPathComponent("OfflineStages/\(UUID().uuidString)/Goldberg")
            preview(try await Task.detached { try OfflineTools.goldberg(package: goldberg, gameRoot: gameRoot, appID: id, dlcs: dlcs, accountName: nickname, language: language, lan: network, achievements: achievements, inventory: inventory, schema: offlineSchema, destination: destination) }.value)
        }
    }
}
