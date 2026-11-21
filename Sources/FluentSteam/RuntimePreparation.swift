import Foundation
import AppKit
import FluentCore

extension AppModel {
    func makeRuntimePreparation() -> RuntimePreparationController {
        let flow = RuntimePreparationController()
        var prepared: OneClickSetup.Prepared?
        flow.mayStart = { [weak self] in guard let self else { return false }; return !self.busy || self.preparationOwnsBusy }
        flow.steamRunning = { [weak self] in self?.steamRunning ?? false }
        flow.inspect = { [weak self] in
            guard let self else { return false }
            let paths = self.paths, application = Bundle.main.bundleURL
            return try await Task.detached { try NativeIntegration.needsPreparation(paths: paths, application: application) }.value
        }
        flow.prepare = { [weak self] in
            guard let self else { return }
            prepared = try await OneClickSetup.prepare(paths: self.paths, options: SetupOptions(), application: Bundle.main.bundleURL)
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
            case .wine: tool = FreeRuntime.installedRoot(self.paths) == nil ? nil : FreeRuntime.toolID
            case .crossOver(let source): tool = try TranslationRuntime.registeredCrossOverTool(paths: self.paths, source: source)
            }
            guard let tool else { return false }
            return try SteamCompatibility.globalTool(config) == tool
        }
        flow.install = { [weak self] in
            guard let self, let prepared else { throw AppFailure("准备记录已失效，请重试 / Preparation expired; retry") }
            if self.preferences.steamAppPath != prepared.paths.steamApp.path {
                var preferences = self.preferences; preferences.steamAppPath = prepared.paths.steamApp.path
                let defaults = self.defaults
                _ = try await Task.detached { try PreferenceStore.save(preferences, defaults: defaults, migrateLua: false) }.value
                self.preferences = preferences; self.setRuntimePaths(prepared.paths)
            }
            let journal = try await OneClickSetup.install(prepared, application: Bundle.main.bundleURL)
            self.log(self.tr("Steam 接入已自动准备；恢复记录：", "Steam integration prepared automatically; recovery records: ") + String(journal.backups.count))
        }
        flow.installBackend = { [weak self, weak flow] backend in
            guard let self else { return }
            let application = Bundle.main.bundleURL, paths = self.paths
            let selectedTool: String
            switch backend {
            case .wine:
                selectedTool = FreeRuntime.toolID
                if FreeRuntime.installedRoot(paths) == nil {
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
        flow.completed = { [weak self] in
            guard let self else { return }
            if let url = self.pendingRuntimeURL {
                self.pendingRuntimeURL = nil; NSWorkspace.shared.open(url)
            }
            guard let request = self.pendingRuntimeLaunch else { return }
            self.pendingRuntimeLaunch = nil
            self.run(self.tr("启动 Steam", "Launch Steam")) {
                if request == 0 { try await self.launchPreparedSteam() }
                else if let game = self.games.first(where: { $0.id == request }) { try await self.launchPreparedGame(game) }
            }
        }
        return flow
    }
    func setRuntimePaths(_ paths: AppPaths) { savedPaths = paths }
    func reconcileRuntimePreparation(retry: Bool = false) {
        guard !testing, !busy else { return }
        let key = [paths.data, paths.steamApp, paths.steam, paths.macSteam, paths.notProton, paths.config].map(\.path).joined(separator: "\n")
        if preparationPathKey != key { preparationPathKey = key; runtimePreparation.reset() }
        Task { await runtimePreparation.reconcile(retry: retry) }
    }
    func chooseTranslationBackend(_ backend: RuntimePreparationController.Backend) {
        guard !testing, !busy else { return }
        Task { await runtimePreparation.choose(backend) }
    }
    func quitSteamForPreparation() {
        // Only a user click requests graceful termination. A game or Steam's
        // confirmation can delay exit; the normal timer resumes after it closes.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam") { app.terminate() }
    }
}
