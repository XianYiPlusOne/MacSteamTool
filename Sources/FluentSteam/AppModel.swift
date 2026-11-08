import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FluentCore

enum Page: String, CaseIterable, Identifiable {
    case library, discover, manifests, trainers, patches, achievements, saves, accounts, runtime, compatibility, settings
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: "square.grid.2x2"; case .discover: "plus.magnifyingglass"; case .manifests: "doc.text"
        case .trainers: "gamecontroller"; case .saves: "externaldrive.badge.icloud"; case .accounts: "person.crop.circle"
        case .runtime: "cpu"; case .compatibility: "checklist"; case .settings: "gearshape"
        case .achievements: "trophy"
        case .patches: "puzzlepiece.extension"
        }
    }
    var titles: (String, String) {
        switch self {
        case .library: ("游戏库", "Library"); case .discover: ("搜索入库", "Discover"); case .manifests: ("清单管理", "Manifests")
        case .trainers: ("修改器", "Trainers"); case .saves: ("存档与备份", "Saves & backups"); case .accounts: ("Steam 账号", "Steam accounts")
        case .runtime: ("运行环境", "Runtime"); case .compatibility: ("功能对照", "Feature parity"); case .settings: ("设置", "Settings")
        case .achievements: ("成就管理", "Achievements")
        case .patches: ("联机补丁", "Online patches")
        }
    }
}
struct ImportSession: Identifiable { let id = UUID(); var plan: ImportPlan }
struct Message: Identifiable { let id = UUID(); var title: String; var detail: String }

@MainActor final class AppModel: ObservableObject {
    @Published var availableUpdate: SignedUpdate?
    @Published var preparedUpdate: PreparedUpdate?
    @Published var updateStatus = ""
    @Published var page: Page = .library
    @Published var games: [Game] = []
    @Published var preferences = Preferences()
    @Published var runtime: RuntimeStatus
    @Published var query = ""
    @Published var filter = "all"
    @Published var search = ""
    @Published var results: [GameMetadata] = []
    @Published var metadata: [Int: GameMetadata] = [:]
    @Published var selectedGame: Game?
    @Published var pendingImport: ImportSession?
    @Published var message: Message?
    @Published var busy = false
    @Published var canCancelOperation = true
    @Published var progress = ""
    @Published var eventLog: [String] = []
    @Published var accounts: [SteamAccount] = []
    @Published var saves: [SaveLocation] = []
    @Published var saveManagerState = SaveManagerState()
    @Published var saveManagerSection: SaveManagerSection = .games
    @Published var saveManagerGameID: Int?
    @Published var saveManagerStatus = ""
    @Published var backups: [BackupRecord] = []
    @Published var trainerResults: [WebDownload] = []
    @Published var needsRestart = false
    @Published var automaticCompatibilityStatus = ""
    @Published var automaticCompatibilityWaiting: [Int] = []
    var automaticCompatibilityTask: Task<Void, Never>?
    var automaticCompatibilityChecked = Date.distantPast
    var automaticCompatibilityError = ""
    @Published var lastRefresh = Date()
    @Published var monitorRunning = false
    @Published var monitorCompleted = 0
    @Published var monitorFailed = 0
    @Published var monitorStatus = ""
    @Published var achievementApp = ""
    @Published var loadedAchievementApp: Int?
    @Published var achievements: [Achievement] = []
    @Published var originalAchievements: [Achievement] = []
    @Published var achievementStatus = ""
    @Published var achievementBackend = "steam"
    @Published var loginQR = ""
    @Published var onlineAccount = ""
    @Published var ownedGames: [OwnedGame] = []
    let defaults: AppPaths
    var paths: AppPaths { preferences.applying(to: defaults) }
    var service: LibraryService { LibraryService(paths: paths) }
    var api: SteamAPI
    var content: ContentService
    var operation: Task<Void, Never>?
    var timer: Timer?
    var fingerprint = ""
    var observedSteamPIDs: [Int32] = []
    var runningTools: [Process] = []
    var trainerMonitors: [UUID: TrainerMonitor] = [:]
    var retiringTrainers: [UUID: TrainerMonitor] = [:]
    var trainerFailures: [UUID: TrainerBinding] = [:]
    @Published var trainerStatus: [UUID: String] = [:]
    var metadataTask: Task<Void, Never>?
    var metadataGeneration = UUID()
    var monitorTask: Task<Void, Never>?
    var didBootstrap = false
    var testing: Bool
    var language: String { preferences.language == "en" ? "english" : "schinese" }
    var steamRunning: Bool { !testing && SteamProcesses.isRunning }
    init() {
        let fixture = ProcessInfo.processInfo.environment["FLUENT_FIXTURE_HOME"]
        testing = fixture != nil
        defaults = fixture.map { AppPaths(home: URL(fileURLWithPath: $0)) } ?? AppPaths()
        api = SteamAPI(cache: defaults.cache.appendingPathComponent("Metadata"))
        content = ContentService(api: api, cache: defaults.cache)
        runtime = .empty
    }
    func bootstrap() async {
        guard !didBootstrap else { return }; didBootstrap = true
        let settings = defaults.settings
        busy = true; progress = tr("读取本地设置", "Read local settings")
        do {
            preferences = try await Task.detached {
                FileStore.fm.fileExists(atPath: settings.path) ? try FileStore.decode(Preferences.self, at: settings) : Preferences()
            }.value
        } catch { message = Message(title: "设置读取失败", detail: error.localizedDescription + "。原文件保留，请检查后重新保存。") }
        await content.configure(preferredCDN: preferences.preferredCDN)
        busy = false; refresh(); AppDelegate.model = self; reconcileTrainerMonitors()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconcileTrainerMonitors()
                guard !self.busy else { return }
                self.reconcileAutomaticCompatibility()
                let pids = SteamProcesses.pids()
                if pids != self.observedSteamPIDs { self.observedSteamPIDs = pids; self.refresh(); return }
                guard self.preferences.autoRefresh else { return }
                let current = self.fileFingerprint()
                if current != self.fingerprint { self.refresh() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
        if !testing && preferences.automaticallyCheckUpdates == true { Task { await checkForUpdates(silent: true) } }
    }
    func tr(_ zh: String, _ en: String) -> String { preferences.language == "en" ? en : zh }
    func title(_ page: Page) -> String { tr(page.titles.0, page.titles.1) }
    var visibleGames: [Game] {
        games.filter { game in
            let matches = query.isEmpty || game.name.localizedCaseInsensitiveContains(query) || String(game.id).contains(query)
            let kind = filter == "all" || (filter == "enabled" && game.enabled) || (filter == "disabled" && !game.enabled && game.source != "Steam") || (filter == "installed" && game.installed != nil)
            return matches && kind
        }
    }
    func fileFingerprint() -> String {
        let files = [paths.config, paths.lua, paths.disabled, paths.backups, paths.depotCache, paths.steam.appendingPathComponent("steamapps/libraryfolders.vdf")] + FileStore.files(paths.lua) + FileStore.files(paths.disabled) + SteamLibrary.libraries(paths).map { $0.appendingPathComponent("steamapps") }
        return files.map(FileStore.fingerprint).joined()
    }
    func refresh() {
        let p = paths
        do {
            games = try SteamLibrary.games(p, metadata: metadata)
            runtime = RuntimeStatus.read(p)
            accounts = (try? Accounts.list(p)) ?? []
            saves = Saves.locations(p)
            refreshSaveManager()
            backups = FileTransaction(backupRoot: p.backups).records()
            fingerprint = fileFingerprint(); lastRefresh = Date()
            if let selected = selectedGame { selectedGame = games.first { $0.id == selected.id } }
            loadMetadata()
            reconcileAutomaticCompatibility()
        } catch { fail(error) }
    }
    func loadMetadata() {
        guard metadataTask == nil, !testing else { return }
        let language = language
        let generation = UUID(); metadataGeneration = generation
        let fetchNames = preferences.autoMetadata
        metadataTask = Task {
            defer { if metadataGeneration == generation { metadataTask = nil } }
            @MainActor func current() -> Bool { !Task.isCancelled && self.language == language && metadataGeneration == generation }
            @MainActor func publish(_ values: [Int: GameMetadata]) {
                guard current() else { return }
                metadata = values
                games = (try? SteamLibrary.games(paths, metadata: metadata)) ?? games
                if let selected = selectedGame { selectedGame = games.first { $0.id == selected.id } }
                do {
                    if try PresenceNames.synchronize(paths: paths, metadata: metadata) {
                        fingerprint = fileFingerprint()
                        backups = FileTransaction(backupRoot: paths.backups).records()
                        log(tr("广播名称已按当前语言同步并备份", "Presence titles localized and backed up"))
                    }
                } catch { log(tr("广播名称同步：", "Presence title sync: ") + error.localizedDescription) }
            }
            let cached = await api.cached(language: language)
            guard current() else { return }
            var localized = cached
            publish(localized)
            guard fetchNames else { return }
            let pending = games.filter { localized[$0.id] == nil }.prefix(24)
            for game in pending {
                guard current() else { return }
                do {
                    let item = try await api.details(game.id, language: language)
                    guard current() else { return }
                    localized[game.id] = item
                    publish(localized)
                } catch { if current() { log("名称查询 \(game.id)：\(error.localizedDescription)") } }
            }
        }
    }
    func log(_ text: String) {
        eventLog.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0)
        if eventLog.count > 150 { eventLog.removeLast() }
    }
    func fail(_ error: Error) { log(error.localizedDescription); message = Message(title: tr("操作未完成", "Operation failed"), detail: error.localizedDescription) }
    func run(_ title: String, cancellable: Bool = true, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; progress = title; canCancelOperation = cancellable
        operation = Task {
            defer { busy = false; operation = nil; canCancelOperation = true }
            do { try await work(); log(title + " · " + tr("完成", "done")) }
            catch is CancellationError { log(tr("操作已取消", "Operation cancelled")) }
            catch { fail(error) }
        }
    }
    func cancel() { if canCancelOperation { operation?.cancel() } }
    func savePreferences() {
        do {
            for value in [preferences.steamPath, preferences.macSteamPath, preferences.luaPath, preferences.notProtonPath] where !value.isEmpty {
                guard value.hasPrefix("/") else { throw AppFailure("目录必须是绝对路径；可以使用右侧选择按钮 / Directory must be an absolute path; use the selection button on the right") }
            }
            let cdn = preferences.preferredCDN?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard cdn.isEmpty || DownloadSources.validCDN(cdn) else { throw AppFailure("CDN 必须是主机名 / CDN must be a hostname") }
            preferences.preferredCDN = cdn
            let feed = preferences.updateFeed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard feed.isEmpty || URL(string: feed)?.scheme == "https" else { throw AppFailure("更新源必须使用 HTTPS / Update feed requires HTTPS") }
            preferences.updateFeed = feed
            Task { await content.configure(preferredCDN: cdn) }
            stopManifestMonitor()
            try FileStore.json(preferences, to: defaults.settings)
            metadata.removeAll(); metadataTask?.cancel(); metadataTask = nil; metadataGeneration = UUID(); refresh()
            reconcileTrainerMonitors()
            log(tr("设置已保存", "Settings saved"))
        } catch { fail(error) }
    }
    func chooseImport() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["lua", "zip", "tar", "7z", "rar", "manifest", "bin"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { prepareImport(panel.urls) }
    }
    func prepareImport(_ urls: [URL]) {
        run(tr("解析导入文件", "Read import files")) {
            let files = try await ArchiveIO.importFiles(urls, engine: self.engineExecutable)
            self.pendingImport = ImportSession(plan: try self.service.plan(files))
        }
    }
    func commitImport() {
        guard let pending = pendingImport else { return }
        run(tr("导入游戏清单", "Import game manifests")) {
            try Task.checkCancellation()
            try self.service.perform(pending.plan); self.pendingImport = nil; self.needsRestart = true; self.refresh()
        }
    }
    func toggle(_ game: Game) {
        run(tr("更新入库状态", "Update library state")) {
            try self.service.setEnabled(game, enabled: !game.enabled); self.needsRestart = true; self.refresh()
        }
    }
    func remove(_ game: Game) {
        run(tr("移除入库记录", "Remove library entry")) {
            try self.service.remove(game); self.needsRestart = true; self.selectedGame = nil; self.refresh()
        }
    }
    func export(_ games: [Game]) {
        guard !games.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = games.count == 1 ? "\(games[0].id)-FluentSteam.zip" : "FluentSteam-Library.zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url {
            run(tr("导出 Lua / Manifest / Bin", "Export Lua / Manifest / Bin")) {
                let service = self.service
                try await Task.detached { try service.export(games, to: url) }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
    func searchGames() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let q = search
        run(tr("搜索 Steam 游戏", "Search Steam")) { self.results = try await self.api.search(q, language: self.language) }
    }
    func generate(_ id: Int, dlc: Bool, existing: Game? = nil) {
        run(tr("生成游戏清单", "Generate game manifest")) {
            let generated = try await self.content.generate(id: id, includeDLC: dlc, preferences: self.preferences) { text in
                await MainActor.run { self.progress = text }
            }
            var text = generated.lua
            if let existing, let url = existing.luaURL { text = try FileStore.text(url) + "\n-- Additional depot and DLC data\n" + text }
            let file = ImportFile(name: "\(id).lua", data: Data(text.utf8))
            var plan = try self.service.plan([file]); plan.warnings += generated.warnings
            self.pendingImport = ImportSession(plan: plan)
        }
    }
    func launchSteam() {
        guard !testing else { return }
        run(tr("启动 Steam", "Launch Steam")) { try await self.launchPreparedSteam() }
    }
    private func launchPreparedSteam() async throws {
        if let task = automaticCompatibilityTask { await task.value }
        let report = try await AutomaticCompatibility.process(paths: paths) { id in try await self.api.compatibilityInfo(id) }
        publishAutomaticCompatibility(report)
        NSWorkspace.shared.openApplication(at: paths.steamApp, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.fail(error) } }
        }
    }
    func reconcileAutomaticCompatibility(force: Bool = false) {
        guard !testing, !busy, automaticCompatibilityTask == nil,
              force || Date().timeIntervalSince(automaticCompatibilityChecked) >= 3 else { return }
        automaticCompatibilityChecked = Date()
        let pendingPaths = paths
        automaticCompatibilityTask = Task {
            defer { automaticCompatibilityTask = nil }
            do {
                let report = try await AutomaticCompatibility.process(paths: pendingPaths, force: force) { id in try await self.api.compatibilityInfo(id) }
                guard paths.steam == pendingPaths.steam, paths.data == pendingPaths.data, paths.config == pendingPaths.config else { return }
                automaticCompatibilityError = ""; publishAutomaticCompatibility(report)
            } catch {
                let text = error.localizedDescription
                automaticCompatibilityStatus = text
                if automaticCompatibilityError != text { log(text); automaticCompatibilityError = text }
            }
        }
    }
    private func publishAutomaticCompatibility(_ report: AutomaticCompatibility.Report) {
        automaticCompatibilityWaiting = report.waitingForSteam
        var messages: [String] = []
        func ids(_ list: [Int]) -> String { list.map(String.init).joined(separator: ", ") }
        if !report.applied.isEmpty {
            let text = tr("已自动选择 NotProton：", "NotProton selected automatically: ") + ids(report.applied)
            log(text); messages.append(text)
        }
        if !report.waitingForSteam.isEmpty {
            needsRestart = true
            messages.append(tr("已识别仅 Windows 内容，退出 Steam 后自动应用：", "Windows-only content detected; applies when Steam exits: ") + ids(report.waitingForSteam))
        }
        if !report.waitingForTool.isEmpty { messages.append(tr("等待安装 NotProton 运行器：", "Waiting for an installed NotProton runtime: ") + ids(report.waitingForTool)) }
        if !report.unresolved.isEmpty { messages.append(tr("平台资料不足，已保留设置并等待重试：", "Platform data incomplete; settings preserved, retry pending: ") + ids(report.unresolved)) }
        automaticCompatibilityStatus = messages.joined(separator: "\n")
    }
    func restartSteam() {
        guard !testing else { log("测试环境不重启真实 Steam"); return }
        run(tr("重启 Steam", "Restart Steam")) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam") { app.terminate() }
            for _ in 0..<30 {
                if !self.steamRunning { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard !self.steamRunning else { throw AppFailure("Steam 尚未退出。请先结束游戏或关闭 Steam 的退出确认窗口 / Steam is still running; finish the game or handle its quit confirmation") }
            try await self.launchPreparedSteam(); self.needsRestart = false
        }
    }
    func launchGame(_ game: Game) {
        guard !testing else { return }
        run(tr("检查运行器并启动游戏", "Check runtime and launch game")) {
            if let task = self.automaticCompatibilityTask { await task.value }
            let report = try await AutomaticCompatibility.process(paths: self.paths) { id in try await self.api.compatibilityInfo(id) }
            self.publishAutomaticCompatibility(report)
            guard !report.waitingForSteam.contains(game.id) else { throw AppFailure("已自动选好 NotProton，请先重启 Steam 应用此设置，再安装或启动游戏 / NotProton is ready; restart Steam to apply it before installing or launching this game") }
            self.openURL("steam://rungameid/\(game.id)")
            self.reconcileTrainerMonitors()
        }
    }
    func launchTrainer(_ binding: TrainerBinding) {
        guard !testing else { log("测试环境不启动 Wine 进程"); return }
        do {
            guard FileStore.fm.fileExists(atPath: binding.executable) else { throw AppFailure("修改器文件已移动或删除 / Trainer file was moved or deleted") }
            let launch = try WineLaunch.prepare(appID: binding.appID, command: binding.executable, paths: paths)
            runningTools.append(try launch.launch(log: paths.data.appendingPathComponent("Logs/trainer-\(binding.appID).log")))
            log(tr("已提交修改器启动请求", "Trainer launch requested"))
        } catch { fail(error) }
    }
    func wineTool(_ game: Game, command: String) {
        guard !testing else { log("测试环境不启动 Wine 工具"); return }
        do { runningTools.append(try WineLaunch.prepare(appID: game.id, command: command, paths: paths).launch(log: paths.data.appendingPathComponent("Logs/wine-\(game.id).log"))) }
        catch { fail(error) }
    }
    func bindTrainer(appID: Int) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "exe")!]
        if panel.runModal() == .OK, let file = panel.url {
            preferences.trainers.append(TrainerBinding(appID: appID, name: file.deletingPathExtension().lastPathComponent, executable: file.path)); savePreferences()
        }
    }
    func searchTrainers(_ q: String) { run(tr("搜索风灵月影修改器", "Search FLiNG trainers")) { self.trainerResults = try await TrainerSearch.search(q) } }
    func downloadTrainer(_ item: WebDownload) {
        run(tr("下载修改器压缩包", "Download trainer archive")) {
            let link = try await TrainerSearch.downloadLink(item.url)
            let data = try await HTTP.get(link, limit: 128 * 1024 * 1024)
            let destination = self.paths.data.appendingPathComponent("Downloads/\(UUID().uuidString.prefix(8))-\(link.lastPathComponent)")
            try FileStore.write(data, to: destination); NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
    func backupSave(_ save: SaveLocation) {
        guard !busy else { return }
        let preferred = saveManagerState.options(for: save.appID).backupDirectory
        if !preferred.isEmpty { performSaveBackup(save, parent: URL(fileURLWithPath: preferred)); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = tr("选择备份位置", "Choose backup location")
        if panel.runModal() == .OK, let dir = panel.url {
            performSaveBackup(save, parent: dir)
        }
    }
    func restoreSave(_ save: SaveLocation, backup: URL? = nil) {
        guard !busy else { return }
        guard !steamRunning else { fail(AppFailure("请先退出游戏和 Steam，再还原存档 / Quit the game and Steam before restoring saves")); return }
        let source: URL
        if let backup { source = backup }
        else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.prompt = tr("选择已校验的备份", "Choose a verified backup")
            guard panel.runModal() == .OK, let selected = panel.url else { return }; source = selected
        }
        run(tr("还原存档", "Restore saves"), cancellable: false) {
            guard !self.steamRunning else { throw AppFailure("请先退出游戏和 Steam，再还原存档 / Quit the game and Steam before restoring saves") }
            let sums = try await Task.detached { try Saves.verifyBackup(source) }.value
            let alert = NSAlert(); alert.messageText = self.tr("还原这份存档备份？", "Restore this save backup?")
            alert.informativeText = "\(sums.count) files\n\(source.path)\n→ \(save.url.path)\n\n" + self.tr("目标目录现有内容会先完整备份，再替换。请确认游戏已退出。", "Current destination files will be backed up before replacement. Make sure the game is closed.")
            alert.addButton(withTitle: self.tr("还原", "Restore")); alert.addButton(withTitle: self.tr("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard !self.steamRunning else { throw AppFailure("Steam 已启动，未还原存档 / Steam started; saves were not restored") }
            let root = self.paths.data.appendingPathComponent("SaveBackups")
            let result = try await Task.detached { try Saves.restore(source, to: save.url, backupRoot: root) }.value
            self.log("Restored \(result.files) verified files")
            var warning: String?
            if let previous = result.previousBackup { warning = await self.recordSaveBackup(save, directory: previous, reason: "before-restore") }
            self.saveManagerStatus = self.tr("已还原并校验 \(result.files) 个文件。", "Restored and verified \(result.files) files.") + (warning.map { "\n" + $0 } ?? "")
            self.refresh()
        }
    }
    func clearSave(_ save: SaveLocation) {
        guard !busy else { return }
        guard !steamRunning else { fail(AppFailure("请先退出游戏和 Steam，再清空存档 / Quit the game and Steam before clearing saves")); return }
        let alert = NSAlert(); alert.messageText = tr("备份后清空此存档目录？", "Back up and clear this save folder?")
        alert.informativeText = save.url.path + "\n\n" + tr("完整备份并校验成功后才会清空。游戏进度将重置，Steam 云端可能重新下载原有存档。请确认游戏已退出。", "Files are removed only after a verified backup. Progress resets; Steam Cloud may download existing saves again. Make sure the game is closed.")
        alert.addButton(withTitle: tr("备份并清空", "Back up and clear")); alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(tr("备份并清空存档", "Back up and clear saves"), cancellable: false) {
            guard !self.steamRunning else { throw AppFailure("请先退出游戏和 Steam / Quit the game and Steam first") }
            let root = self.paths.data.appendingPathComponent("SaveBackups")
            let result = try await Task.detached { try Saves.clear(save.url, backupRoot: root) }.value
            var warning: String?
            if let previous = result.previousBackup { warning = await self.recordSaveBackup(save, directory: previous, reason: "before-clear") }
            self.saveManagerStatus = self.tr("已备份并清空所选目录。", "Selected folder backed up and cleared.") + (warning.map { "\n" + $0 } ?? self.tr("可在此游戏的备份记录中恢复。", " Restore it from this game's backup history."))
            self.refresh()
        }
    }
    func restore(_ record: BackupRecord) {
        run(tr("还原备份", "Restore backup")) {
            guard !self.steamRunning else { throw AppFailure("请先退出 Steam，再还原配置备份 / Quit Steam before restoring configuration") }
            try FileTransaction(backupRoot: self.paths.backups).restore(record, allowedRoots: [self.paths.steam, self.paths.macSteam, self.paths.lua, self.paths.data])
            self.needsRestart = true; self.refresh()
        }
    }
    func switchAccount(_ account: SteamAccount) {
        run(tr("切换本地账号", "Switch local account")) {
            guard !self.steamRunning else { throw AppFailure("请先退出 Steam，再切换本地账号 / Quit Steam before switching local accounts") }
            try Accounts.select(account, paths: self.paths); self.refresh(); try await self.launchPreparedSteam()
        }
    }
    func repairManifest(depot: Int, manifest: String) {
        run(tr("获取并校验 Manifest", "Download and verify manifest")) {
            let data = try await self.content.fetchManifest(depot: depot, manifest: manifest, template: self.preferences.manifestURL, fallbacks: self.preferences.manifestFallbacks != false)
            let url = self.paths.depotCache.appendingPathComponent("\(depot)_\(manifest).manifest")
            try FileTransaction(backupRoot: self.paths.backups).apply([(url, data)], reason: "下载 Manifest \(depot)")
            self.refresh()
        }
    }
    var achievementChanges: [AchievementChange] {
        let original = Dictionary(uniqueKeysWithValues: originalAchievements.map { ($0.id, $0.achieved) })
        return achievements.compactMap { row in
            guard let old = original[row.id], old != row.achieved else { return nil }
            return AchievementChange(id: row.id, expected: old, achieved: row.achieved)
        }
    }
    func readAchievements() {
        guard let id = TextUtil.validID(achievementApp) else { return }
        // A failed read must not leave another game's editable state on screen.
        loadedAchievementApp = nil; achievements = []; originalAchievements = []; achievementStatus = ""
        run(tr("读取 Steam 成就", "Read Steam achievements")) {
            guard !self.testing, self.steamRunning else { throw AppFailure("请先在原生 Steam 中登录；测试环境不会连接真实账号 / Sign in to native Steam first; the fixture environment does not connect to real accounts") }
            var request = AchievementRequest(appID: id, library: self.paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib").path)
            if AchievementRepair.enabled(appID: id, paths: self.paths) { request.compatibilityRoot = self.paths.data.path }
            let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluentSteamWorker")
            let response = try await AchievementWorker.run(request, executable: worker)
            self.achievements = response.achievements; self.originalAchievements = response.achievements
            self.loadedAchievementApp = id; self.achievementBackend = response.backend ?? "steam"
            self.achievementStatus = response.backend == "compatibility" ? self.tr("已读取当前账号的兼容记录", "Loaded this account's compatibility records") : self.tr("已读取 Steam 当前状态", "Loaded current Steam state")
        }
    }
    func repairAchievements() {
        guard let id = TextUtil.validID(achievementApp) else { return }
        run(tr("初始化兼容成就", "Initialize compatible achievements")) {
            guard !self.testing, self.steamRunning else { throw AppFailure("请先登录并启动 Steam / Start Steam and sign in first") }
            try await AchievementRepair.prepare(appID: id, paths: self.paths, worker: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluentSteamWorker"))
            self.achievementStatus = self.tr("定义已取得；重启 Steam 后读取成就。兼容记录保存到当前账号的本机/已配置统计云端。", "Schema ready. Restart Steam, then load achievements. Compatibility records use this account's local/configured statistics storage.")
        }
    }
    func saveAchievements() {
        guard let id = loadedAchievementApp, !achievementChanges.isEmpty else { return }
        let changes = achievementChanges
        let compatible = achievementBackend == "compatibility"
        let alert = NSAlert(); alert.messageText = compatible ? tr("保存兼容成就记录？", "Save compatibility achievements?") : tr("保存成就更改到 Steam？", "Save achievement changes to Steam?")
        alert.informativeText = "App \(id) · \(changes.count) " + (compatible ? tr("项更改。保存后会重读并校验本机记录；这不表示写入 Valve 账号服务器。", "changes. The local record will be reread and verified; this does not mean Valve account servers accepted it.") : tr("项更改。成功回调后才会显示已保存。", "changes. Saved status requires a successful Steam callback."))
        alert.addButton(withTitle: tr("保存到 Steam", "Save to Steam")); alert.addButton(withTitle: tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(tr("保存 Steam 成就", "Save Steam achievements")) {
            guard !self.testing, self.steamRunning else { throw AppFailure("Steam 未运行，无法写入 / Steam is not running; cannot write changes") }
            let snapshot = self.paths.data.appendingPathComponent("AchievementBackups/\(id)-\(UUID().uuidString).json")
            try FileStore.json(self.originalAchievements, to: snapshot)
            var request = AchievementRequest(appID: id, library: self.paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib").path, changes: changes)
            if compatible { request.compatibilityRoot = self.paths.data.path }
            let response = try await AchievementWorker.run(request, executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluentSteamWorker"))
            guard response.stored else { throw AppFailure("Steam 未确认保存；请重新读取确认状态 / Steam did not confirm the save; reread to confirm its state") }
            self.achievements = response.achievements; self.originalAchievements = response.achievements
            self.achievementBackend = response.backend ?? "steam"
            self.achievementStatus = response.backend == "compatibility" ? self.tr("兼容记录已保存、重读并校验；非 Valve 服务器确认", "Compatibility record saved, reread and verified; not a Valve server acknowledgement") : self.tr("Steam 已返回保存成功回调", "Steam acknowledged that the changes were stored")
        }
    }
    func stopManifestMonitor() {
        monitorTask?.cancel(); monitorTask = nil; monitorRunning = false
        monitorStatus = tr("已停止", "Stopped")
    }
    func startManifestMonitor() {
        guard !monitorRunning else { return }
        let p = paths, template = preferences.manifestURL, fallbacks = preferences.manifestFallbacks != false
        do {
            var tail = try ContentLogTail(url: p.steam.appendingPathComponent("logs/content_log.txt"))
            monitorRunning = true; monitorCompleted = 0; monitorFailed = 0
            monitorStatus = tr("监听新请求；在 Steam 中重试下载", "Watching new requests; retry the download in Steam")
            monitorTask = Task {
                do {
                    while !Task.isCancelled {
                        let requests = try tail.poll()
                        for request in requests {
                            try Task.checkCancellation()
                            guard self.games.contains(where: { $0.id == request.app && $0.enabled }) else { continue }
                            let target = p.depotCache.appendingPathComponent(request.key + ".manifest")
                            if let existing = try? FileStore.read(target), (try? SteamManifest.validate(existing, depot: request.depot, manifest: request.manifest)) != nil { continue }
                            self.monitorStatus = "App \(request.app) · Depot \(request.depot)"
                            do {
                                let data = try await self.content.fetchManifest(depot: request.depot, manifest: request.manifest, template: template, fallbacks: fallbacks)
                                try Task.checkCancellation()
                                try FileTransaction(backupRoot: p.backups).apply([(target, data)], reason: "监听修复 Manifest \(request.depot)")
                                self.monitorCompleted += 1
                                self.log("Manifest \(request.key) · " + self.tr("校验并写入成功，请重试 Steam 下载", "Verified and saved; retry the download in Steam"))
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                if Task.isCancelled { throw CancellationError() }
                                self.monitorFailed += 1; self.log("Manifest \(request.key) · \(error.localizedDescription)")
                            }
                            try await Task.sleep(for: .milliseconds(800))
                        }
                        self.monitorStatus = self.tr("正在监听新增请求", "Watching new requests")
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch is CancellationError { }
                catch { self.monitorRunning = false; self.monitorStatus = error.localizedDescription; self.log(error.localizedDescription) }
            }
        } catch { fail(error) }
    }
    func openURL(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFolder(_ url: URL) {
        guard FileStore.fm.fileExists(atPath: url.path) else { message = Message(title: tr("目录尚未创建", "Folder does not exist"), detail: url.path); return }
        NSWorkspace.shared.open(url)
    }
    func openCompanion(_ name: String) {
        let path = URL(fileURLWithPath: "/Applications/\(name).app")
        guard FileStore.fm.fileExists(atPath: path.path) else { fail(AppFailure("未找到 / Not found \(name).app，请先安装 / Install the application first")); return }; NSWorkspace.shared.open(path)
    }
}
