import Foundation
import AppKit
import MacSteamToolCore

extension AppModel {
    func makeRuntimePreparation() -> RuntimePreparationController {
        let flow = RuntimePreparationController()
        var prepared: OneClickSetup.Prepared?
        flow.mayStart = { [weak self] in guard let self else { return false }; return !self.guideSteamInstallation.isRunning && (!self.busy || self.preparationOwnsBusy) }
        flow.stateChanged = { [weak self] state in
            guard let self else { return }
            let active = state == .preparing || state == .installing
            if active {
                self.preparationOwnsBusy = true; self.busy = true; self.canCancelOperation = false
                self.progress = self.tr("正在自动准备游戏环境", "Preparing your gaming environment automatically")
            } else if self.preparationOwnsBusy {
                self.preparationOwnsBusy = false; self.busy = false; self.canCancelOperation = true
                self.refresh()
            }
        }
        if testing {
            configureIsolatedWine(flow)
            return flow
        }
        flow.steamRunning = { [weak self] in self?.steamRunning ?? false }
        flow.inspect = { [weak self] in
            guard let self else { return false }
            let paths = self.paths, application = Bundle.main.bundleURL
            return try await Task.detached { try NativeIntegration.needsPreparation(paths: paths, application: application) }.value
        }
        flow.prepare = { [weak self, weak flow] in
            guard let self else { return }
            prepared = try await OneClickSetup.prepare(paths: self.paths, options: SetupOptions(), application: Bundle.main.bundleURL) { [weak flow] message in
                await flow?.reportProgress(message)
            }
        }
        flow.requiresRosetta = { [weak flow] in
            guard prepared.map(OneClickSetup.requiresRosetta) == true || flow?.pendingBackend != nil else { return false }
            return !(await OneClickSetup.rosettaAvailable())
        }
        flow.authorizeRosetta = { try await OneClickSetup.installRosetta(consent: true) }
        flow.backendReady = { [weak self] backend in
            guard let self, let config = try? FileStore.read(self.paths.steam.appendingPathComponent("config/config.vdf")) else { return false }
            let tool: String?
            switch backend {
            case .localWine(let source): tool = LocalWine.registered(self.paths) == source ? LocalWine.toolID : nil
            case .wine: tool = FreeRuntime.graphicsReady(self.paths) ? FreeRuntime.toolID : nil
            case .crossOver(let source): tool = try TranslationRuntime.registeredCrossOverTool(paths: self.paths, source: source)
            }
            guard let tool else { return false }
            return try SteamCompatibility.globalTool(config) == tool
        }
        flow.install = { [weak self, weak flow] in
            guard let self, let prepared else { throw AppFailure("准备记录已失效，请重试 / Preparation expired; retry") }
            if self.preferences.steamAppPath != prepared.paths.steamApp.path {
                var preferences = self.preferences; preferences.steamAppPath = prepared.paths.steamApp.path
                let defaults = self.defaults
                _ = try await Task.detached { try PreferenceStore.save(preferences, defaults: defaults, migrateLua: false) }.value
                self.preferences = preferences; self.setRuntimePaths(prepared.paths)
            }
            let journal = try await OneClickSetup.install(prepared, application: Bundle.main.bundleURL) { [weak flow] message in
                await flow?.reportProgress(message)
            }
            self.log(self.tr("Steam 接入已自动准备；恢复记录：", "Steam integration prepared automatically; recovery records: ") + String(journal.backups.count))
        }
        flow.installBackend = { [weak self, weak flow] backend in
            guard let self else { return }
            let application = Bundle.main.bundleURL, paths = self.paths
            let selectedTool: String
            switch backend {
            case .localWine(let source):
                if LocalWine.registered(paths) != source { try await LocalWine.register(source, paths: paths) }
                selectedTool = LocalWine.toolID
            case .wine:
                selectedTool = FreeRuntime.toolID
                if !FreeRuntime.graphicsReady(paths) {
                    try await FreeRuntime.install(paths: paths, resources: application.appendingPathComponent("Contents/Resources/FreeRuntime"), cloudHelper: application.appendingPathComponent("Contents/Helpers/Cloud/cloud_redirect.dylib"), progress: { [weak flow] message in
                        await flow?.reportProgress(message)
                    })
                }
            case .crossOver(let source):
                if try TranslationRuntime.registeredCrossOverTool(paths: paths, source: source) == nil {
                    try await TranslationRuntime.installCrossOver(paths: paths, crossOver: source, application: application)
                }
                guard let selected = try TranslationRuntime.registeredCrossOverTool(paths: paths, source: source) else { throw AppFailure("所选 CrossOver 的运行器尚未就绪 / The selected CrossOver runtime is not ready") }
                selectedTool = selected
            }
            try SteamCompatibility.chooseDefault(paths: paths, tool: selectedTool)
            self.log(self.tr("游戏兼容层已就绪", "Game translation backend is ready"))
        }
        flow.completed = { [weak self] in _ = self?.openPendingSteamRequest() }
        return flow
    }
    private func configureIsolatedWine(_ flow: RuntimePreparationController) {
        let home = self.home.standardizedFileURL.resolvingSymlinksInPath()
        // Use only fixture defaults. Saved preferences can point to a real Steam library.
        var fixture = AppPaths(home: home)
        fixture.steamApp = home.appendingPathComponent("Applications/Steam.app")
        let paths = fixture
        flow.idleState = { [weak self] in
            if self?.previewCrossOver.map(GuideEnvironment.isCrossOverApplication) == true { return .ready }
            if LocalWine.isDefault(paths) { return LocalWine.registered(paths) == nil ? .wineNotInstalled : .ready }
            return FreeRuntime.graphicsReady(paths) ? .ready : .wineNotInstalled
        }
        flow.backendReady = { [weak self] backend in
            switch backend {
            case .localWine(let source): return self?.previewCrossOver == nil && LocalWine.isDefault(paths) && LocalWine.registered(paths) == source
            case .wine: return self?.previewCrossOver == nil && !LocalWine.isDefault(paths) && FreeRuntime.graphicsReady(paths)
            case .crossOver(let app): return self?.previewCrossOver == app && GuideEnvironment.isCrossOverApplication(app)
            }
        }
        flow.installBackend = { [weak self, weak flow] backend in
            if case .crossOver(let app) = backend {
                guard GuideEnvironment.isCrossOverApplication(app) else {
                    throw AppFailure("请选择包含 Wine 运行器的 CrossOver 应用 / Select a CrossOver app containing its Wine runner")
                }
                self?.previewCrossOver = app
                return
            }
            let temporaryRoots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
            guard temporaryRoots.contains(where: { home.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }),
                  [paths.data, paths.cache.appendingPathComponent("FreeRuntime"), FreeRuntime.root(paths),
                   FreeRuntime.tool(paths), paths.steam.appendingPathComponent("config"), paths.steamApp].allSatisfy({ $0.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") }) else {
                throw AppFailure("请使用独立的临时目录测试 Wine 安装 / Use a private temporary directory to test Wine installation")
            }
            if case .localWine(let source) = backend {
                try await LocalWine.register(source, paths: paths, home: home, requireIdle: {})
                try SteamCompatibility.chooseDefault(paths: paths, tool: LocalWine.toolID, requireIdle: {})
                self?.previewCrossOver = nil
                return
            }
            if !FreeRuntime.graphicsReady(paths) {
                guard await OneClickSetup.rosettaAvailable() else {
                    throw AppFailure("Wine 需要 Rosetta 2，请先在 macOS 中安装，然后重试 / Install Rosetta 2 in macOS before retrying Wine setup")
                }
                let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/FreeRuntime")
                try await FreeRuntime.install(paths: paths, resources: resources, installerHome: home,
                                              steamRunning: { false }) { [weak flow] message in
                    await flow?.reportProgress(message)
                }
                guard FreeRuntime.graphicsReady(paths) else {
                    throw AppFailure("隔离目录中的 Wine 文件不完整，请重试 / Wine files in the isolated directory are incomplete. Retry setup.")
                }
            }
            if LocalWine.isDefault(paths) {
                try SteamCompatibility.chooseDefault(paths: paths, tool: FreeRuntime.toolID, requireIdle: {})
            }
            self?.previewCrossOver = nil
        }
    }
    func setRuntimePaths(_ paths: AppPaths) { savedPaths = paths }
    // Let Launch Services choose the client's architecture, including the user's
    // Rosetta preference. Opening an installed client needs no integration profile.
    private func openPendingSteamRequest() -> Bool {
        guard !testing, !busy, let request = pendingSteamLaunch else { return false }
        let selected = OneClickSetup.resolveSteamPath(paths)
        guard NativeSteamBootstrap.isSteamApplication(selected.steamApp) else { return false }
        pendingSteamLaunch = nil
        run(tr("打开 Steam", "Open Steam")) {
            guard !RuntimeInstaller.backups(selected).contains(where: \.interrupted) else {
                throw AppFailure("请先在诊断与恢复中恢复中断的安装 / Recover the interrupted installation in Diagnostics and recovery first")
            }
            switch request {
            case .url(let url): try await self.openSteamApplication(selected.steamApp, url)
            case .client: try await self.launchPreparedSteam(at: selected.steamApp)
            case .game(let id): try await self.launchPreparedGame(id, at: selected.steamApp)
            }
        }
        return true
    }
    func reconcileRuntimePreparation(retry: Bool = false) {
        guard !busy, !guideSteamInstallation.isRunning else { return }
        if openPendingSteamRequest() { return }
        let key = [paths.data, paths.steamApp, paths.steam, paths.macSteam, paths.notProton, paths.config].map(\.path).joined(separator: "\n")
        if preparationPathKey != key { preparationPathKey = key; runtimePreparation.reset() }
        // The guide installs the Valve client first; backend preparation follows the user's choice.
        if !testing, page == .guide, !retry, runtimePreparation.pendingBackend == nil,
           guideSteamInstallation.installedApp != nil || !FileManager.default.fileExists(atPath: guideSteamDestination.path) { return }
        Task { await runtimePreparation.reconcile(retry: retry) }
    }
    func chooseTranslationBackend(_ backend: RuntimePreparationController.Backend) {
        guard !busy, !guideSteamInstallation.isRunning else { return }
        Task { await runtimePreparation.choose(backend) }
    }
    func quitSteamForPreparation() {
        // Only a user click requests graceful termination. A game or Steam's
        // confirmation can delay exit; the normal timer resumes after it closes.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam") { app.terminate() }
    }
}
