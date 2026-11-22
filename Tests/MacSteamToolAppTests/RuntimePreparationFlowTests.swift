import Foundation
import Testing
@testable import MacSteamToolCore
@testable import MacSteamTool

@Suite @MainActor struct RuntimePreparationFlowTests {
    @Test func missingProfileIsReportedWithoutAskingToQuitRunningSteam() async {
        let flow = RuntimePreparationController()
        let missing = SteamProfileUnavailable.client(build: "123", architectures: [.x86_64])
        var inspections = 0
        flow.inspect = { inspections += 1; throw missing }
        flow.steamRunning = { true }
        flow.prepare = { Issue.record("Unsupported setup reached preparation") }
        flow.install = { Issue.record("Unsupported setup reached installation") }
        await flow.reconcile()
        #expect(flow.state == .failed(missing.localizedDescription))
        await flow.reconcile()
        #expect(inspections == 1)
        await flow.reconcile(retry: true)
        #expect(inspections == 2)
    }

    @Test(arguments: ["arm64", "x86_64", "universal"])
    func installedSteamOpensWithoutRuntimePreparation(architecture: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(fixtureHome: home)
        var paths = model.defaults
        paths.steamApp = home.appendingPathComponent("Selected Steam.app")
        let contents = paths.steamApp.appendingPathComponent("Contents")
        let info = ["CFBundleIdentifier": NativeSteamBootstrap.bundleIdentifier, "CFBundleExecutable": "steam_osx"]
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
                            to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/steam_osx")
        try FileStore.mkdir(executable.deletingLastPathComponent())
        let source = home.appendingPathComponent("client.c")
        try FileStore.write(Data("int main(void) { return 0; }".utf8), to: source)
        let slices = architecture == "universal" ? ["arm64", "x86_64"] : [architecture]
        let (code, _) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/clang"),
            slices.flatMap { ["-arch", $0] } + [source.path, "-o", executable.path])
        try #require(code == 0)
        #expect(RuntimeStatus.read(paths).steamArchitectures.map(\.rawValue) == slices)
        let prepared = OneClickSetup.Prepared(paths: paths, options: SetupOptions(), steam: paths.steamApp, awaitingFirstSteamLaunch: true)
        let hardware = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "hw.optional.arm64"])
        let appleSilicon = hardware.0 == 0 && hardware.1.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        #expect(OneClickSetup.requiresRosetta(prepared) == (architecture == "x86_64" && appleSilicon))
        model.setRuntimePaths(paths)
        model.preferences.automaticallyPrepareAchievements = false
        var launches: [URL?] = []
        model.openSteamApplication = { application, url in
            #expect(application == paths.steamApp)
            launches.append(url)
        }
        model.testing = false
        model.runtimePreparation.steamRunning = { false }
        model.runtimePreparation.inspect = { throw AppFailure("Unsupported integration profile") }
        await model.runtimePreparation.reconcile()
        #expect(model.runtimePreparation.state == .failed("Unsupported integration profile"))
        model.launchSteam()
        await model.operation?.value
        let game = Game(id: 480, name: "Fixture", enabled: true)
        model.games = [game]
        model.launchGame(game)
        await model.operation?.value
        model.openSteamClientURL("steam://nav/games")
        await model.operation?.value
        #expect(launches.map { $0?.absoluteString } == [nil, "steam://rungameid/480", "steam://nav/games"])
    }

    @Test func guideSteamInstallStagesLeadToBackendChoice() {
        let target = URL(fileURLWithPath: "/Applications/Steam.app")
        let found = GuideEnvironment(steam: target, wineInstalled: false, activeBackend: nil)
        #expect(GuideStep(environment: nil, runtime: .checking, hasPendingChoice: false, installer: .downloading) == .downloadingSteam)
        #expect(GuideStep(environment: nil, runtime: .ready, hasPendingChoice: false, installer: .installing) == .installingSteam)
        #expect(GuideStep(environment: nil, runtime: .checking, hasPendingChoice: false, installer: .failed("offline")) == .steamFailure("offline"))
        #expect(GuideStep(environment: found, runtime: .checking, hasPendingChoice: false, installer: .installed(target)) == .choice)
    }

    @Test func guideInstallerKeepsAnOccupiedDestination() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(fixtureHome: home)
        let target = home.appendingPathComponent("Applications/Steam.app")
        let bytes = Data("existing file".utf8)
        try FileStore.write(bytes, to: target)
        await model.installSteamFromGuide()
        guard case .failed = model.guideSteamInstallation else { Issue.record("Expected an install error"); return }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func guideAdvancesOnlyWhenTheUsersSetupIsReady() {
        let steam = URL(fileURLWithPath: "/Applications/Steam.app")
        let clean = GuideEnvironment(steam: steam, wineInstalled: false, activeBackend: nil)
        let ready = GuideEnvironment(steam: steam, wineInstalled: true, activeBackend: "Wine")
        let missing = GuideEnvironment(steam: nil, wineInstalled: true, activeBackend: "Wine")
        #expect(GuideStep(environment: nil, runtime: .ready, hasPendingChoice: false) == .checking)
        #expect(GuideStep(environment: missing, runtime: .ready, hasPendingChoice: false) == .steam)
        #expect(GuideStep(environment: clean, runtime: .ready, hasPendingChoice: false) == .choice)
        #expect(GuideStep(environment: clean, runtime: .wineNotInstalled, hasPendingChoice: false) == .choice)
        #expect(GuideStep(environment: ready, runtime: .ready, hasPendingChoice: true) == .checking)
        #expect(GuideStep(environment: ready, runtime: .ready, hasPendingChoice: false) == .complete)
        #expect(GuideStep(environment: nil, runtime: .needsRosetta, hasPendingChoice: true) == .rosetta)
        #expect(GuideStep(environment: ready, runtime: .waitingForSteam, hasPendingChoice: true) == .quitSteam)
        #expect(GuideStep(environment: clean, runtime: .failed("offline"), hasPendingChoice: true) == .failure("offline"))
    }
    @Test func isolatedCrossOverChoiceChecksTheAppAndLeavesSteamUntouched() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(fixtureHome: home)
        let app = home.appendingPathComponent("CrossOver.app")
        let flow = model.runtimePreparation
        await flow.choose(.crossOver(app))
        guard case .failed = flow.state else { Issue.record("Missing CrossOver should require another choice"); return }
        let info = ["CFBundleIdentifier": "com.codeweavers.CrossOver", "CFBundlePackageType": "APPL"]
        try FileStore.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: app.appendingPathComponent("Contents/Info.plist"))
        let runner = app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
        try FileStore.write(Data(), to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        await flow.choose(.crossOver(app))
        #expect(flow.ready && model.previewCrossOver == app)
        #expect(!FileManager.default.fileExists(atPath: model.defaults.steam.path))
        #expect(!FileManager.default.fileExists(atPath: FreeRuntime.root(model.defaults).path))
    }
    @Test func guideOpensOnceAndSetupRemainsPendingAcrossLaunches() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AppModel(fixtureHome: home)
        #expect(first.page == .guide)
        first.markGuideSeen()
        let next = AppModel(fixtureHome: home)
        #expect(next.page == .library)
        #expect(!next.runtimePreparation.ready)
    }

    @Test func guideReusesLocalWineAndLaunchesWithItsOwnPrefix() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(fixtureHome: home), paths = model.defaults
        let wine = home.appendingPathComponent(".local/bin/wine")
        let script = #"""
        #!/bin/sh
        if [ "$1" = --version ]; then echo wine-11.0; exit 0; fi
        printf '%s\n' "$WINEPREFIX" "$@"
        """#
        try FileStore.write(Data(script.utf8), to: wine)
        try FileStore.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        func snapshot() -> GuideEnvironment {
            GuideEnvironment.read(paths: paths, isolated: true, previewCrossOver: nil, home: home)
        }
        #expect(snapshot().detectedWine == wine)
        #expect(snapshot().activeBackend == nil)
        await model.runtimePreparation.choose(.localWine(wine))
        #expect(model.runtimePreparation.ready)
        #expect(snapshot().activeBackend == "Wine")
        #expect(LocalWine.registered(paths) == wine)
        #expect(LocalWine.isDefault(paths))
        #expect(!FileStore.fm.fileExists(atPath: paths.cache.appendingPathComponent("FreeRuntime").path))
        let root = paths.steam.appendingPathComponent("steamapps/compatdata/123")
        let tool = paths.steam.appendingPathComponent("compatibilitytools.d").appendingPathComponent(LocalWine.toolID).appendingPathComponent("run")
        var env = FreeRuntime.environment()
        env["STEAM_COMPAT_DATA_PATH"] = root.path
        let (queryStatus, query) = try await ProcessRunner.run(tool, ["getcompatpath"], environment: env)
        #expect(queryStatus == 0)
        let data = root.appendingPathComponent("macsteamtool-local-wine")
        #expect(query.trimmingCharacters(in: .newlines) == data.path)
        env["STEAM_COMPAT_DATA_PATH"] = data.path
        let args = ["game with spaces.exe", "$(literal)", "A & B"]
        let (status, output) = try await ProcessRunner.run(tool, ["waitforexitandrun"] + args, environment: env)
        let prefix = data.appendingPathComponent("pfx")
        #expect(status == 0)
        #expect(output.components(separatedBy: "\n") == [prefix.path] + args + [""])
        try FileStore.mkdir(prefix)
        let launch = try WineLaunch.prepare(appID: 123, command: "winecfg", paths: paths)
        #expect(launch.executable == wine)
        let launchedPrefix = try #require(launch.environment["WINEPREFIX"])
        #expect(URL(fileURLWithPath: launchedPrefix).resolvingSymlinksInPath().path == prefix.resolvingSymlinksInPath().path)
        let container = try #require(GameContainers.all(paths).first { $0.runtime == .localWine })
        #expect(try GameContainers.backend(for: container, paths: paths)?.id == LocalWine.toolID)
        let backup = try await GameContainers.backup(container, paths: paths, requireIdle: {})
        #expect(backup.runtime == .localWine)
        #expect(GameContainers.backups(GameContainer(appID: 123, library: paths.steam, isWine: true), paths: paths).isEmpty)
        let relaunched = AppModel(fixtureHome: home)
        await relaunched.runtimePreparation.reconcile()
        #expect(relaunched.runtimePreparation.ready)
        try FileStore.fm.removeItem(at: wine)
        await relaunched.runtimePreparation.reconcile()
        #expect(relaunched.runtimePreparation.state == .wineNotInstalled)
        #expect(snapshot().activeBackend == nil)
    }

    @Test func isolatedFirstLaunchLeavesCheckingAndWineChoiceReachesInstaller() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(fixtureHome: home)
        let flow = model.runtimePreparation
        await model.bootstrap()
        defer { model.timer?.invalidate() }
        for _ in 0..<100 where flow.state == .checking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(flow.state == .wineNotInstalled)
        var attempts = 0
        flow.installBackend = { backend in
            #expect(backend == .wine)
            attempts += 1
            throw AppFailure("offline")
        }
        model.chooseTranslationBackend(.wine)
        for _ in 0..<100 where attempts == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(flow.state == .failed("offline"))
        #expect(!model.busy)
        await flow.reconcile()
        #expect(attempts == 1)
        await flow.reconcile(retry: true)
        #expect(attempts == 2)
    }

    @Test func isolatedWineChoiceVerifiesTheSessionArchive() async throws {
        guard await OneClickSetup.rosettaAvailable() else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(fixtureHome: home)
        let archive = model.defaults.cache.appendingPathComponent("FreeRuntime").appendingPathComponent(FreeRuntime.assetName)
        try FileStore.write(Data("incomplete download".utf8), to: archive)
        let flow = model.runtimePreparation
        await flow.choose(.wine)
        guard case .failed(let message) = flow.state else {
            Issue.record("An invalid session archive must stop installation")
            return
        }
        #expect(message.contains("digest mismatch"))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(FreeRuntime.installedRoot(model.defaults) == nil)
    }

    @Test func existingSettingsKeepTheLibraryAsTheStartupPage() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileStore.json(Preferences(), to: AppPaths(home: home).settings)
        #expect(AppModel(fixtureHome: home).page == .library)
    }

    @Test func choosingAlreadyActiveBackendDoesNotAskToExitSteam() async {
        let flow = RuntimePreparationController()
        flow.steamRunning = { true }
        flow.backendReady = { $0 == .wine }
        var installs = 0
        flow.installBackend = { _ in installs += 1 }
        await flow.choose(.wine)
        #expect(flow.ready && installs == 0 && flow.pendingBackend == nil)
    }
    @Test func firstLaunchInitializesOnceAndHealthySteamNeverNeedsExit() async {
        let flow = RuntimePreparationController()
        var needed = true, installs = 0, running = false
        flow.inspect = { needed }; flow.steamRunning = { running }
        flow.install = { installs += 1; needed = false }
        await flow.reconcile()
        #expect(flow.ready && installs == 1)
        running = true
        await flow.reconcile(); await flow.reconcile()
        #expect(flow.ready && installs == 1)
    }
    @Test func keepsChoiceWhileWaitingAndResumesWithoutAnotherClick() async {
        let flow = RuntimePreparationController()
        var running = true, needed = true, installs = 0, backends: [RuntimePreparationController.Backend] = []
        flow.inspect = { needed }; flow.steamRunning = { running }
        flow.install = { installs += 1; needed = false }
        flow.installBackend = { backends.append($0) }
        await flow.choose(.crossOver(URL(fileURLWithPath: "/Applications/My CrossOver.app")))
        #expect(flow.state == .waitingForSteam && installs == 0 && backends.isEmpty)
        await flow.reconcile()
        #expect(flow.state == .waitingForSteam)
        running = false; await flow.reconcile()
        #expect(flow.ready && installs == 1 && backends.count == 1 && flow.pendingBackend == nil)
    }
    @Test func detectsSteamUpdateAndRechecksExitAfterPreparation() async {
        let flow = RuntimePreparationController()
        var needed = false, running = false, installs = 0
        flow.inspect = { needed }; flow.steamRunning = { running }
        flow.install = { installs += 1; needed = false }
        await flow.reconcile(); #expect(flow.ready)
        needed = true
        flow.prepare = { running = true }
        await flow.reconcile()
        #expect(flow.state == .waitingForSteam && installs == 0)
        running = false; flow.prepare = {}
        await flow.reconcile()
        #expect(flow.ready && installs == 1)
    }
    @Test func requestsRosettaOnlyWhenNeededAndCancellationKeepsChoice() async {
        let flow = RuntimePreparationController()
        var needsRosetta = true, allow = false, authorizations = 0, backendInstalls = 0
        flow.requiresRosetta = { needsRosetta }
        flow.authorizeRosetta = {
            authorizations += 1
            if !allow { throw AppFailure("User canceled") }
            needsRosetta = false
        }
        flow.installBackend = { _ in backendInstalls += 1 }
        await flow.choose(.wine)
        #expect(flow.state == .needsRosetta && authorizations == 0 && backendInstalls == 0)
        await flow.reconcile()
        #expect(authorizations == 0)
        await flow.grantRosettaConsent()
        #expect(flow.state == .needsRosetta && flow.pendingBackend == .wine && authorizations == 1)
        allow = true; await flow.grantRosettaConsent()
        #expect(flow.ready && authorizations == 2 && backendInstalls == 1)
    }
    @Test func failureIsLatchedAndRetryVerifiesBeforeReportingReady() async {
        let flow = RuntimePreparationController()
        var needed = true, calls = 0, fixed = false
        flow.inspect = { needed }
        flow.install = { calls += 1; if fixed { needed = false } else { throw AppFailure("rollback retained") } }
        await flow.reconcile(); await flow.reconcile(); await flow.reconcile()
        #expect(flow.state == .failed("rollback retained") && calls == 1)
        fixed = true; await flow.reconcile(retry: true)
        #expect(flow.ready && calls == 2)
    }
    @Test func bootstrapProcessRejectionWaitsAndResumesAutomatically() async {
        let flow = RuntimePreparationController()
        var needed = true, bootstrapRunning = true
        flow.inspect = { needed }
        // The UI has not observed the bootstrap's executable path yet.
        flow.steamRunning = { false }
        flow.install = {
            if bootstrapRunning { throw SteamPreparationRequiresExit() }
            needed = false
        }
        await flow.reconcile()
        #expect(flow.state == .waitingForSteam)
        bootstrapRunning = false
        await flow.reconcile()
        #expect(flow.ready)
    }
    @Test func concurrentTicksCoalesceAndOtherOperationsDeferMutation() async {
        let flow = RuntimePreparationController()
        var allowed = false, needed = true, calls = 0
        flow.mayStart = { allowed }; flow.inspect = { needed }
        flow.install = { calls += 1; try await Task.sleep(for: .milliseconds(25)); needed = false }
        await flow.reconcile(); #expect(calls == 0)
        allowed = true
        async let first: Void = flow.reconcile()
        async let second: Void = flow.reconcile()
        _ = await (first, second)
        #expect(flow.ready && calls == 1)
    }
}
