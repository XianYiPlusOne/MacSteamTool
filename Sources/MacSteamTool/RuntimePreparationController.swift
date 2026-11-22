import Foundation
import SwiftUI
import MacSteamToolCore

/// Coordinates automatic initialization and a user's queued backend choice.
/// Waiting states release the UI; repeated ticks never repeat a failed mutation.
@MainActor final class RuntimePreparationController: ObservableObject {
    enum State: Equatable { case checking, preparing, waitingForSteam, needsRosetta, installing, wineNotInstalled, ready, failed(String) }
    enum Backend: Equatable { case wine, localWine(URL), crossOver(URL) }
    @Published private(set) var state: State = .checking { didSet { stateChanged(state) } }
    @Published private(set) var pendingBackend: Backend?
    @Published private(set) var detail = ""
    var stateChanged: (State) -> Void = { _ in }
    var idleState: () -> State = { .ready }
    var completed: () -> Void = {}
    var mayStart: () -> Bool = { true }
    var inspect: () async throws -> Bool = { false }
    var steamRunning: () -> Bool = { false }
    var prepare: () async throws -> Void = {}
    var requiresRosetta: () async -> Bool = { false }
    var authorizeRosetta: () async throws -> Void = {}
    var install: () async throws -> Void = {}
    var installBackend: (Backend) async throws -> Void = { _ in }
    var backendReady: (Backend) async throws -> Bool = { _ in false }
    private var task: Task<Void, Never>?
    var working: Bool { state == .preparing || state == .installing }
    var ready: Bool { state == .ready && pendingBackend == nil }
    func reportProgress(_ message: String) { detail = message }
    func choose(_ backend: Backend) async {
        guard !working else { return }
        pendingBackend = backend
        await reconcile(retry: true)
    }
    func reconcile(retry: Bool = false) async {
        if let task { await task.value; return }
        guard mayStart() else { return }
        if !retry {
            if case .failed = state { return }
            if state == .needsRosetta { return }
        }
        task = Task { await advance() }
        await task?.value
        task = nil
    }
    private func advance() async {
        do {
            let needed = try await inspect()
            guard mayStart() else { return }
            if let backend = pendingBackend, try await backendReady(backend) { pendingBackend = nil }
            if !needed && pendingBackend == nil {
                let idle = idleState()
                if state != idle { state = idle }
                if ready { completed() }
                return
            }
            if steamRunning() { state = .waitingForSteam; return }
            state = .preparing; detail = ""
            if needed { try await prepare() }
            if await requiresRosetta() { detail = ""; state = .needsRosetta; return }
            // Steam may have restarted during download or authorization.
            if steamRunning() { state = .waitingForSteam; return }
            state = .installing
            if needed {
                try await install()
                guard !(try await inspect()) else { throw AppFailure("准备后校验未通过，已保留恢复记录 / Preparation verification failed; recovery records were retained") }
            }
            if let backend = pendingBackend {
                if steamRunning() { state = .waitingForSteam; return }
                try await installBackend(backend)
                pendingBackend = nil
            }
            state = .ready; completed()
        } catch {
            if error is SteamPreparationRequiresExit || steamRunning() { state = .waitingForSteam }
            else { state = .failed(error.localizedDescription) }
        }
    }
    /// Called only by the explicit Rosetta license/authorization control.
    func grantRosettaConsent() async {
        guard task == nil, state == .needsRosetta, mayStart() else { return }
        task = Task {
            state = .preparing
            do { try await authorizeRosetta(); state = .checking }
            catch { detail = error.localizedDescription; state = .needsRosetta }
        }
        await task?.value; task = nil
        if state == .checking { await reconcile() }
    }
    func reset() {
        guard task == nil else { return }
        state = .checking; detail = ""; pendingBackend = nil
    }
}
