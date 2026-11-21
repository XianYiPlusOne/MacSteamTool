import Foundation
import Testing
@testable import FluentCore
@testable import FluentSteam

@Suite @MainActor struct RuntimePreparationFlowTests {
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
