import AppKit
import MacSteamToolCore

/// A read-only snapshot for the guide. Installed applications are discovered without starting them.
struct GuideEnvironment {
    let steam: URL?
    let wineInstalled: Bool
    let activeBackend: String?
    var detectedCrossOver: URL? = nil
    var detectedWine: URL? = nil
    var usingLocalWine = false

    static func read(paths: AppPaths, isolated: Bool, previewCrossOver: URL?, installedSteam: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let steam = locateSteam(preferred: installedSteam ?? (isolated ? home.appendingPathComponent("Applications/Steam.app") : paths.steamApp))
        let wineInstalled = FreeRuntime.graphicsReady(paths)
        let registeredWine = LocalWine.registered(paths)
        let config = try? FileStore.read(paths.steam.appendingPathComponent("config/config.vdf"))
        let selected = config.flatMap { try? SteamCompatibility.globalTool($0) }
        var backend: String?
        if isolated {
            if previewCrossOver.map(isCrossOverApplication) == true { backend = "CrossOver" }
            else if selected == LocalWine.toolID { backend = registeredWine == nil ? nil : "Wine" }
            else if wineInstalled { backend = "Wine" }
        } else if let selected {
            if selected == LocalWine.toolID { backend = registeredWine == nil ? nil : "Wine" }
            else if selected == FreeRuntime.toolID {
                backend = wineInstalled ? "Wine" : nil
            } else if let runner = try? GameContainers.backends(paths).first(where: { $0.id == selected }),
                      FileManager.default.isExecutableFile(atPath: paths.notProton.appendingPathComponent("runners/crossover-\(runner.build)/CrossOver/bin/wine").path) {
                backend = runner.name
            }
        }
        let directories = [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")]
        let candidates = directories.flatMap { dir in
            ["CrossOver.app", "CrossOver Preview.app"].map { dir.appendingPathComponent($0) }
        } + ["com.codeweavers.CrossOver", "com.codeweavers.CrossOver-Preview"].flatMap(registeredApplications)
        let crossOver = ([previewCrossOver].compactMap { $0 } + candidates).first(where: isCrossOverApplication)
        let wineApps = directories.flatMap { dir in
            ["Wine Stable.app", "Wine Staging.app", "Wine Devel.app", "Wine Development.app", "Wine.app"].map { dir.appendingPathComponent($0) }
        }
        let knownWineApps = ["org.winehq.wine-stable.wine", "org.winehq.wine-staging.wine", "org.winehq.wine-devel.wine"].flatMap(registeredApplications)
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        let bins = [home.appendingPathComponent(".local/bin"), home.appendingPathComponent("bin")]
            + (["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + searchPath.map(String.init)).map { URL(fileURLWithPath: $0) }
        let wine = registeredWine ?? LocalWine.detect(applications: wineApps + knownWineApps, binaries: bins)
        return Self(steam: steam, wineInstalled: wineInstalled, activeBackend: backend, detectedCrossOver: crossOver, detectedWine: wine,
                    usingLocalWine: backend == "Wine" && selected == LocalWine.toolID && registeredWine != nil)
    }

    private static func registeredApplications(_ id: String) -> [URL] {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).filter { url in
            let path = url.resolvingSymlinksInPath().path
            return !path.hasPrefix(temporary) && !path.contains("/.Trash/")
                && (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == false
        }
    }

    static func isCrossOverApplication(_ app: URL) -> Bool {
        guard app.pathExtension.lowercased() == "app",
              Bundle(url: app)?.bundleIdentifier?.lowercased().hasPrefix("com.codeweavers.crossover") == true else { return false }
        let wine = app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").resolvingSymlinksInPath()
        return (try? wine.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && FileManager.default.isExecutableFile(atPath: wine.path)
    }

    static func locateSteam(preferred: URL?) -> URL? {
        let directories = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let candidates = [preferred].compactMap { $0 } + directories.map { $0.appendingPathComponent("Steam.app") }
        if let app = candidates.first(where: NativeSteamBootstrap.isSteamApplication) { return app }
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: NativeSteamBootstrap.bundleIdentifier).first { url in
            let readOnly = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
            return readOnly != true && NativeSteamBootstrap.isSteamApplication(url)
        }
    }
}

enum GuideStep: Equatable {
    case checking, steam, downloadingSteam, installingSteam, steamFailure(String), choice, working, quitSteam, rosetta, failure(String), complete

    @MainActor init(environment: GuideEnvironment?, runtime: RuntimePreparationController.State, hasPendingChoice: Bool, installer: GuideSteamInstallation = .idle) {
        switch installer {
        case .downloading: self = .downloadingSteam; return
        case .installing: self = .installingSteam; return
        case .failed(let reason) where environment?.steam == nil: self = .steamFailure(reason); return
        default: break
        }
        // Requests that need a response stay visible even if Steam is being installed.
        switch runtime {
        case .failed(let error): self = .failure(error)
        case .needsRosetta: self = .rosetta
        case .waitingForSteam: self = .quitSteam
        case .preparing, .installing: self = .working
        default:
            guard let environment else { self = .checking; return }
            guard environment.steam != nil else { self = .steam; return }
            if hasPendingChoice || (runtime == .checking && installer.installedApp == nil) { self = .checking }
            else if runtime == .ready, environment.activeBackend != nil { self = .complete }
            else { self = .choice }
        }
    }
}
