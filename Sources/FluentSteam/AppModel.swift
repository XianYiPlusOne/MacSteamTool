import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FluentCore

enum Page: String, CaseIterable, Identifiable {
    case library, discover, manifests, multiplayer, offlineTools, achievements, saves, accounts, runtime, containers, compatibility, settings
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: "square.grid.2x2"; case .discover: "plus.magnifyingglass"; case .manifests: "doc.text"
        case .saves: "externaldrive.badge.icloud"; case .accounts: "person.crop.circle"
        case .runtime: "cpu"; case .compatibility: "checklist"; case .settings: "gearshape"
        case .achievements: "trophy"
        case .multiplayer: "network"
        case .offlineTools: "wrench.and.screwdriver"
        case .containers: "shippingbox"
        }
    }
    var titles: (String, String) {
        switch self {
        case .library: ("游戏库", "Library"); case .discover: ("搜索入库", "Discover"); case .manifests: ("清单管理", "Manifests")
        case .saves: ("存档与备份", "Saves & backups"); case .accounts: ("Steam 账号", "Steam accounts")
        case .runtime: ("运行环境", "Runtime"); case .compatibility: ("功能对照", "Feature parity"); case .settings: ("设置", "Settings")
        case .achievements: ("成就管理", "Achievements")
        case .multiplayer: ("联机", "Multiplayer")
        case .offlineTools: ("离线工具", "Offline tools")
        case .containers: ("容器管理", "Containers")
        }
    }
}
struct ImportSession: Identifiable {
    let id = UUID()
    var plan: ImportPlan
    var automatic = false
    var complete = true
    var notes: [String] = []
    var includeDLC = true
    var excludedDLC: Set<Int> = []
    var checkLog: [String] = []
    var content: [LibraryContentReport] = []
    var unavailableDLC: Set<Int> {
        Set(content.filter { $0.isUnavailableOptionalDLC }.map(\.id))
            .subtracting(excludedDLC)
    }
    var verificationDepots: Set<Int> = []
    var installContext: LibraryInstallContext?
}
struct Message: Identifiable { let id = UUID(); var title: String; var detail: String }
@MainActor final class AppModel: ObservableObject {
    let multiplayer = MultiplayerController()
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
    @Published var metadata: [Int: GameMetadata] = [:]
    @Published var selectedGame: Game?
    @Published var containerAppID: Int?
    @Published var importActivity: LibraryImportActivity?
    @Published var pendingImport: ImportSession?
    @Published var pendingAuthorizedRepair: ImportSession?
    var authorizedRepairFetch: ((Int, Set<Int>, Bool) async throws -> SteamEngineResponse)?
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
    @Published var removalRequest: RemovalRequest?
    @Published var saveRecoveryRequest: SaveRecoveryRequest?
    var remindedSaveApps: Set<Int> = []
    @Published var needsRestart = false
    @Published var automaticCompatibilityStatus = ""
    @Published var automaticCompatibilityWaiting: [Int] = []
    var automaticCompatibilityTask: Task<Void, Never>?
    var automaticCompatibilityChecked = Date.distantPast
    var automaticCompatibilityError = ""
    @Published var lastRefresh = Date()
    @Published var hubMonitorRunning = false
    @Published var hubMonitorCompleted = 0
    @Published var hubMonitorFailed = 0
    @Published var hubMonitorStatus = ""
    var hubMonitorTask: Task<Void, Never>?
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
    @Published var automaticAchievementsStatus = ""
    var automaticAchievementsTask: Task<Void, Never>?
    var automaticAchievementsChecked = Date.distantPast
    @Published var loginQR = ""
    @Published var onlineAccount = ""
    @Published var ownedGames: [OwnedGame] = []
    let home: URL
    let defaults: AppPaths
    var savedPaths: AppPaths?
    lazy var runtimePreparation = makeRuntimePreparation()
    var preparationOwnsBusy = false
    var preparationPathKey = ""
    var pendingRuntimeLaunch: Int?
    var pendingRuntimeURL: URL?
    var paths: AppPaths { savedPaths ?? defaults }
    var service: LibraryService { LibraryService(paths: paths) }
    let charts: DiscoveryChartsFlow
    let discoverySearch: DiscoverySearchFlow
    let covers: GameCovers
    var api: SteamAPI
    var content: ContentService
    var operation: Task<Void, Never>?
    var timer: Timer?
    var fingerprint = ""
    var observedSteamPIDs: [Int32] = []
    var runningTools: [Process] = []
    var metadataTask: Task<Void, Never>?
    var metadataGeneration = UUID()
    // Steamworks Common Redistributables has a local name but no Store game page.
    private static let sharedComponentAppIDs: Set<Int> = [228980]
    var monitorTask: Task<Void, Never>?
    var didBootstrap = false
    var remotePackageFetch: ((Int, Preferences, URL) async throws -> [ImportFile])?
    var libraryPackageFallbacks: (Int) -> [AutomaticLibraryImport.RemoteSource] = RemoteLuaPackage.libraryFallbacks
    var libraryInfoFetch: ((Int) async throws -> AppInfo)?
    var libraryKeyFetch: ((Bool) async throws -> [Int: String])?
    var hubCredentialLoad: () throws -> ManifestHubCredential? = { try ManifestHubCredential.load() }
    var manifestFetch: ((Int, String, String) async throws -> Data)?
    var testing: Bool
    var language: String { preferences.language == "en" ? "english" : "schinese" }
    var steamRunning: Bool { !testing && SteamProcesses.isRunning }
    init(fixtureHome: URL? = nil, chartStore: DiscoveryChartStore? = nil) {
        let fixture = fixtureHome?.path ?? ProcessInfo.processInfo.environment["FLUENT_FIXTURE_HOME"]
        testing = fixture != nil
        home = fixture.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        defaults = fixture.map { AppPaths(home: URL(fileURLWithPath: $0)) } ?? AppPaths()
        charts = DiscoveryChartsFlow(store: chartStore ?? DiscoveryChartStore(file: defaults.cache.appendingPathComponent("Charts/popular.json")))
        covers = GameCovers(cache: defaults.cache.appendingPathComponent("Covers"))
        let api = SteamAPI(cache: defaults.cache.appendingPathComponent("Metadata"))
        self.api = api
        discoverySearch = DiscoverySearchFlow { try await api.searchPage($0, language: $1, offset: $2) }
        content = ContentService(api: api, cache: defaults.cache)
        runtime = .empty
    }
    func bootstrap() async {
        guard !didBootstrap else { return }; didBootstrap = true
        let settings = defaults.settings
        busy = true; progress = tr("读取本地设置", "Read local settings")
        do {
            let home = home, defaults = defaults, fixture = testing
            try await Task.detached {
                if fixture { try RetiredFeatureCleanup.run(home: home, paths: defaults, launchctl: { _ in 113 }) }
                else { try RetiredFeatureCleanup.run(home: home, paths: defaults) }
            }.value
        } catch { message = Message(title: tr("升级清理未完成", "Upgrade cleanup incomplete"), detail: error.localizedDescription) }

        do {
            preferences = try await Task.detached {
                FileStore.fm.fileExists(atPath: settings.path) ? try FileStore.decode(Preferences.self, at: settings) : Preferences()
            }.value
        } catch { message = Message(title: "设置读取失败", detail: error.localizedDescription + "。原文件保留，请检查后重新保存。") }
        savedPaths = preferences.applying(to: defaults)
        await content.configure(preferredCDN: preferences.preferredCDN)
        busy = false; refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.busy else { return }
                self.reconcileRuntimePreparation()
                self.reconcileAutomaticCompatibility()
                self.reconcileAutomaticAchievements()
                let pids = SteamProcesses.pids()
                if pids != self.observedSteamPIDs { self.observedSteamPIDs = pids; self.refresh(); return }
                guard self.preferences.autoRefresh else { return }
                self.remindSaveRecoveryIfReady()
                let current = self.fileFingerprint()
                if current != self.fingerprint { self.refresh() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel) }
        reconcileRuntimePreparation()
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
            reconcileAutomaticAchievements()
            remindSaveRecoveryIfReady()
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
            let pending = games.filter {
                !Self.sharedComponentAppIDs.contains($0.id) && localized[$0.id] == nil
            }.prefix(24)
            for game in pending {
                guard current() else { return }
                do {
                    let item = try await api.details(game.id, language: language)
                    guard current() else { return }
                    localized[game.id] = item
                    publish(localized)
                } catch {
                    if current() {
                        log(tr("后台名称查询 \(game.id)：", "Background name lookup \(game.id): ") + error.localizedDescription)
                    }
                }
            }
        }
    }
    func log(_ text: String) {
        eventLog.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0)
        if eventLog.count > 150 { eventLog.removeLast() }
    }
    func fail(_ error: Error) { log(error.localizedDescription); message = Message(title: tr("操作未完成", "Operation failed"), detail: error.localizedDescription) }
    func run(_ title: String, cancellable: Bool = true, logCompletion: Bool = true, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; progress = title; canCancelOperation = cancellable
        operation = Task {
            defer { busy = false; operation = nil; canCancelOperation = true }
            do { try await work(); if logCompletion { log(title + " · " + tr("完成", "done")) } }
            catch is CancellationError { finishImportProgress(tr("操作已取消，未继续入库", "Cancelled; import stopped"), cancelled: true); log(tr("操作已取消", "Operation cancelled")) }
            catch { finishImportProgress(error.localizedDescription, failed: true); fail(error) }
        }
    }
    func cancel() { if canCancelOperation { operation?.cancel() } }
    func savePreferences(migrateLua: Bool = true, stopManifest: Bool = true) {
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
            let saved = preferences, defaults = defaults
            run(tr("保存设置", "Save settings"), cancellable: false) {
                if stopManifest { self.stopManifestMonitor() }
                let result = try await Task.detached { try PreferenceStore.save(saved, defaults: defaults, migrateLua: migrateLua) }.value
                self.savedPaths = saved.applying(to: defaults)
                await self.content.configure(preferredCDN: cdn)
                self.metadata.removeAll(); self.metadataTask?.cancel(); self.metadataTask = nil; self.metadataGeneration = UUID(); self.refresh()
                if let result { self.log(self.tr("Lua 已迁移 \(result.copied) 个，一致 \(result.identical) 个；原目录保留。", "Lua: copied \(result.copied), identical \(result.identical); original folder retained.")) }
            }
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
        guard !busy, let pending = pendingImport else { return }
        run(tr("导入游戏清单", "Import game manifests"), logCompletion: false) {
            try Task.checkCancellation()
            if pending.automatic {
                guard pending.complete else {
                    throw AppFailure("游戏内容缺失或尚未核实，请补齐并重新检查后入库；未修改游戏库 / Content missing or unverified; complete the check before importing. Library unchanged")
                }
                guard let context = pending.installContext, let appID = pending.plan.documents.first?.appID,
                      try LibraryInstallContext.read(appID: appID, paths: self.paths) == context else {
                    throw AppFailure("游戏运行设置已变化，请重新入库 / Game runtime settings changed; retry the import")
                }
            }
            try self.service.perform(pending.plan); self.pendingImport = nil; self.refresh()
            await self.refreshSteamAfterImport(appID: pending.plan.documents.first?.appID)
            self.offerSaveRecovery(pending.plan.documents.map(\.appID))
        }
    }
    func excludeUnverifiedDLC() {
        guard let session = pendingImport, session.automatic,
              let id = session.plan.documents.first?.appID else { return }
        let excluded = session.unavailableDLC
        guard !excluded.isEmpty else { return }
        pendingImport = nil
        addToLibrary(id, dlc: session.includeDLC, excludingDLC: excluded.union(session.excludedDLC))
    }
    func cancelImport() {
        guard pendingImport != nil else { return }
        pendingImport = nil
        log(tr("已取消入库，未写入游戏库", "Import cancelled; library unchanged"))
    }
    func batchLibrary(_ games: [Game], action: LibraryService.BatchAction) {
        guard !games.isEmpty else { return }
        if action == .remove { requestGameRemoval(games); return }
        run(tr("批量更新游戏库", "Update selected library entries"), cancellable: false) {
            try self.service.batch(games, action: action)
            self.needsRestart = true; self.refresh()
        }
    }
    func toggle(_ game: Game) {
        run(tr("更新入库状态", "Update library state")) {
            try self.service.setEnabled(game, enabled: !game.enabled); self.needsRestart = true; self.refresh()
        }
    }
    func remove(_ game: Game) { requestGameRemoval([game]) }
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
        guard !busy else { return }
        discoverySearch.search(search, language: language)
    }

    func addToLibrary(_ id: Int, dlc: Bool, excludingDLC: Set<Int> = []) {
        guard !busy, !games.contains(where: { $0.id == id && $0.enabled }) else { return }
        message = nil
        importActivity = LibraryImportActivity(appID: id, title: tr("正在准备检查…", "Preparing check…"))
        recordImportProgress(tr("开始检查 AppID \(id)", "Starting check for AppID \(id)"))
        recordImportProgress(dlc ? tr("检查范围：主游戏及 DLC", "Scope: main game and DLC") : tr("检查范围：仅主游戏", "Scope: main game only"))
        if !excludingDLC.isEmpty { recordImportProgress(tr("本次排除 DLC：", "Excluded DLC: ") + excludingDLC.sorted().map(String.init).joined(separator: ", ")) }
        run(tr("添加到游戏库", "Add to library"), logCompletion: false) {
            await Task.yield()
            let preferences = self.preferences
            let context = try LibraryInstallContext.read(appID: id, paths: self.paths)
            let result = try await AutomaticLibraryImport.resolve(appID: id, includeDLC: dlc, excludingDLC: excludingDLC, skipUnavailableDLC: true, context: context, appInfo: { appID in
                if let fetch = self.libraryInfoFetch { return try await fetch(appID) }
                return try await self.api.appInfo(appID)
            }, cachedKeys: {
                if let fetch = self.libraryKeyFetch { return try await fetch(false) }
                return try await self.content.libraryKeys(preferences: preferences, refresh: false)
            }, steamCachedKeys: { missing in
                try SteamLibrary.cachedDepotKeys(missing, paths: self.paths)
            }, refreshKeys: {
                if let fetch = self.libraryKeyFetch { return try await fetch(true) }
                return try await self.content.libraryKeys(preferences: preferences, refresh: true)
            }, remote: {
                if let fetch = self.remotePackageFetch { return try await fetch(id, preferences, self.engineExecutable) }
                return try await RemoteLuaPackage.fetch(appID: id, preferences: preferences, engine: self.engineExecutable,
                    progress: { self.recordImportProgress($0) })
            }, remoteFallbacks: self.libraryPackageFallbacks(id), contentUpdate: { self.importActivity?.content = $0 },
               progress: { self.recordImportProgress($0) })
            try Task.checkCancellation()
            guard try LibraryInstallContext.read(appID: id, paths: self.paths) == context else {
                throw AppFailure("游戏运行设置已变化，请重新入库 / Game runtime settings changed; retry the import")
            }
            for note in result.notes { self.recordImportProgress(note) }
            self.recordImportProgress(self.tr("正在生成导入预览并检查兼容性…", "Preparing import preview and checking compatibility…"))
            var plan = try self.service.plan(result.files)
            plan.warnings = Array(Set(plan.warnings + result.warnings)).sorted()
            self.importActivity?.content = result.content
            for warning in plan.warnings { self.recordImportProgress(warning) }
            self.recordImportProgress(self.tr("检查结束，等待在导入预览中确认", "Checks finished; awaiting confirmation in import preview"))
            self.pendingImport = ImportSession(plan: plan, automatic: true, complete: result.complete, notes: result.notes,
                includeDLC: dlc, excludedDLC: excludingDLC.union(result.skippedDLC), checkLog: self.importActivity?.logs ?? [], content: result.content, verificationDepots: result.verificationDepots, installContext: context)
            self.importActivity = nil
            self.log(result.complete
                ? self.tr("待确认导入，尚未写入游戏库", "Awaiting import confirmation; library unchanged")
                : self.tr("内容缺失或待核实，尚未入库", "Content missing or unverified; not added to library"))
        }
    }
    func generate(_ id: Int, dlc: Bool, existing: Game? = nil) {
        if existing == nil { addToLibrary(id, dlc: dlc); return }
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
        guard !testing, !busy else { return }
        pendingRuntimeURL = nil; pendingRuntimeLaunch = 0
        reconcileRuntimePreparation()
    }
    func launchPreparedSteam() async throws {
        if let task = automaticAchievementsTask { await task.value }
        if preferences.automaticallyPrepareAchievements != false && !steamRunning {
            publishAutomaticAchievements(try await AutomaticAchievements.process(paths: paths) { _ in })
        }
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
            let text = tr("已自动应用所选兼容层：", "Selected translation backend applied automatically: ") + ids(report.applied)
            log(text); messages.append(text)
        }
        if !report.waitingForSteam.isEmpty {
            needsRestart = true
            messages.append(tr("已识别仅 Windows 内容，退出 Steam 后自动应用：", "Windows-only content detected; applies when Steam exits: ") + ids(report.waitingForSteam))
        }
        if !report.waitingForTool.isEmpty { messages.append(tr("请选择游戏兼容层：", "Choose a game translation backend: ") + ids(report.waitingForTool)) }
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
            self.pendingRuntimeLaunch = 0; self.needsRestart = false
        }
    }
    func launchGame(_ game: Game) {
        guard !testing, !busy else { return }
        pendingRuntimeURL = nil; pendingRuntimeLaunch = game.id
        reconcileRuntimePreparation()
    }
    func launchPreparedGame(_ game: Game) async throws {
        if let task = automaticCompatibilityTask { await task.value }
        let report = try await AutomaticCompatibility.process(paths: paths) { id in try await self.api.compatibilityInfo(id) }
        publishAutomaticCompatibility(report)
        guard !report.waitingForSteam.contains(game.id) else { throw AppFailure("请重启 Steam 应用此游戏的兼容层设置 / Restart Steam to apply the game's compatibility settings") }
        openURL("steam://rungameid/\(game.id)")
    }
    func wineTool(_ game: Game, command: String) {
        guard !testing else { log("测试环境不启动 Wine 工具"); return }
        do { runningTools.append(try WineLaunch.prepare(appID: game.id, command: command, paths: paths).launch(log: paths.data.appendingPathComponent("Logs/wine-\(game.id).log"))) }
        catch { fail(error) }
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
    func restore(_ record: BackupRecord, appIDs: [Int]? = nil) {
        run(tr("还原备份", "Restore backup")) {
            guard !self.steamRunning else { throw AppFailure("请先退出 Steam，再还原配置备份 / Quit Steam before restoring configuration") }
            try self.service.restoreBackup(record, appIDs: appIDs)
            self.needsRestart = true; self.refresh()
            if let ids = try appIDs ?? self.service.restoreGameIDs(record) { self.offerSaveRecovery(ids) }
        }
    }
    func switchAccount(_ account: SteamAccount) {
        run(tr("切换本地账号", "Switch local account")) {
            guard !self.steamRunning else { throw AppFailure("请先退出 Steam，再切换本地账号 / Quit Steam before switching local accounts") }
            try Accounts.select(account, paths: self.paths); self.refresh(); self.pendingRuntimeLaunch = 0
        }
    }
    func fetchSelectedManifest(depot: Int, manifest: String, source: String? = nil, template: String? = nil, fallbacks: Bool? = nil) async throws -> Data {
        let selected = source ?? preferences.manifestSource ?? "code"
        if let manifestFetch { return try await manifestFetch(depot, manifest, selected) }
        if selected == "hub" {
            guard let key = try hubCredentialLoad() else { throw AppFailure("请先保存 ManifestHub API Key / Save a ManifestHub API key first") }
            return try await ManifestHub.fetch(depot: depot, manifest: manifest, credential: key)
        }
        return try await content.fetchManifest(depot: depot, manifest: manifest, template: template ?? preferences.manifestURL, fallbacks: fallbacks ?? (preferences.manifestFallbacks != false))
    }
    func repairManifest(depot: Int, manifest: String) {
        run(tr("获取并校验 Manifest", "Download and verify manifest")) {
            let data = try await self.fetchSelectedManifest(depot: depot, manifest: manifest)
            try SteamManifest.validate(data, depot: depot, manifest: manifest)
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
    func stopManifestMonitor(source: String? = nil) {
        if source == nil || source == "code" { monitorTask?.cancel(); monitorTask = nil; monitorRunning = false; monitorStatus = tr("已停止", "Stopped") }
        if source == nil || source == "hub" { hubMonitorTask?.cancel(); hubMonitorTask = nil; hubMonitorRunning = false; hubMonitorStatus = tr("已停止", "Stopped") }
    }
    private func publishMonitor(_ source: String, status: String? = nil, running: Bool? = nil, completed: Int? = nil, failed: Int? = nil) {
        if source == "hub" {
            if let status { hubMonitorStatus = status }; if let running { hubMonitorRunning = running }
            if let completed { hubMonitorCompleted = completed }; if let failed { hubMonitorFailed = failed }
        } else {
            if let status { monitorStatus = status }; if let running { monitorRunning = running }
            if let completed { monitorCompleted = completed }; if let failed { monitorFailed = failed }
        }
    }
    func startManifestMonitor(source requested: String? = nil) {
        let source = requested ?? preferences.manifestSource ?? "code"
        guard !(source == "hub" ? hubMonitorRunning : monitorRunning) else { return }
        let p = paths, template = preferences.manifestURL, fallbacks = preferences.manifestFallbacks != false
        do {
            if source == "hub" {
                guard let key = try hubCredentialLoad(), key.expiry > Date() else { throw AppFailure("请先保存有效的 ManifestHub Key / Save a valid ManifestHub key first") }
            }
            var tail = try ContentLogTail(url: p.steam.appendingPathComponent("logs/content_log.txt"))
            stopManifestMonitor(source: source == "hub" ? "code" : "hub")
            publishMonitor(source, status: tr("监听新请求；在 Steam 中重试下载", "Watching new requests; retry the download in Steam"), running: true, completed: 0, failed: 0)
            let task = Task {
                var completed = 0, failed = 0
                do {
                    while !Task.isCancelled {
                        for request in try tail.poll() {
                            try Task.checkCancellation()
                            guard self.games.contains(where: { $0.id == request.app && $0.enabled }) else { tail.allowRetry(request); continue }
                            let target = p.depotCache.appendingPathComponent(request.key + ".manifest")
                            if let existing = try? FileStore.read(target), (try? SteamManifest.validate(existing, depot: request.depot, manifest: request.manifest)) != nil { continue }
                            self.publishMonitor(source, status: "App \(request.app) · Depot \(request.depot)")
                            do {
                                let data = try await self.fetchSelectedManifest(depot: request.depot, manifest: request.manifest, source: source, template: template, fallbacks: fallbacks)
                                try Task.checkCancellation()
                                try SteamManifest.validate(data, depot: request.depot, manifest: request.manifest)
                                // The other monitor may already have fulfilled the same request.
                                if (try? FileStore.read(target)) != data {
                                    try FileTransaction(backupRoot: p.backups).apply([(target, data)], reason: "\(source) 监听修复 Manifest \(request.depot)")
                                }
                                completed += 1; self.publishMonitor(source, completed: completed)
                                self.log("\(source) Manifest \(request.key) · " + self.tr("已校验写入，请重试 Steam 下载", "Verified and saved; retry Steam download"))
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                if Task.isCancelled { throw CancellationError() }
                                tail.allowRetry(request)
                                failed += 1; self.publishMonitor(source, failed: failed)
                                self.log("\(source) Manifest \(request.key) · \(error.localizedDescription)")
                                if source == "hub", let hubError = error as? ManifestHubFailure, hubError.stopsMonitor { throw error }
                            }
                            try await Task.sleep(for: .milliseconds(800))
                        }
                        self.publishMonitor(source, status: self.tr("正在监听新增请求", "Watching new requests"))
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch is CancellationError { }
                catch { self.publishMonitor(source, status: error.localizedDescription, running: false); self.log(error.localizedDescription) }
            }
            if source == "hub" { hubMonitorTask = task } else { monitorTask = task }
        } catch { fail(error) }
    }
    func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        if url.scheme == "steam", !testing, !runtimePreparation.ready {
            pendingRuntimeLaunch = nil; pendingRuntimeURL = url; reconcileRuntimePreparation(); return
        }
        NSWorkspace.shared.open(url)
    }
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
