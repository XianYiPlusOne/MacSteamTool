import Foundation

public struct PatchLoadCheck: Codable, Sendable {
    public enum State: String, Codable, Sendable { case loaded, partial, notLoaded, notRunning, inconclusive }
    public let state: State
    public let date: Date
    public let processID: UInt32?
    public let loaded: [String]
    public let missing: [String]
    public let detail: String
}
public enum PatchLoadVerification {
    private struct Request: Encodable { let nonce: String; let executable: String; let modules: [String] }
    private struct Response: Decodable {
        struct ProcessEntry: Decodable { let pid: UInt32; let created: String; let loaded: [Bool] }
        let ok: Bool; let complete: Bool; let nonce: String?; let processes: [ProcessEntry]?; let error: String?
    }
    public static func assertStopped(target: PatchWindowsTarget, appID: Int, paths: AppPaths) async throws {
        let launch = try target.launch(appID: appID, command: target.executable, paths: paths)
        // -w only waits for this prefix's server. It neither starts a Windows client nor
        // terminates applications, and avoids creating a registry cache before deployment.
        let waiter = Process(); waiter.executableURL = URL(fileURLWithPath: target.server); waiter.arguments = ["-w"]
        waiter.environment = launch.environment; waiter.standardOutput = FileHandle.nullDevice; waiter.standardError = FileHandle.nullDevice
        try waiter.run(); defer { if waiter.isRunning { waiter.terminate() } }
        let end = Date().addingTimeInterval(8)
        while waiter.isRunning && Date() < end { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100)) }
        guard !waiter.isRunning else { throw AppFailure("所选 Windows 容器中仍有程序或 Wine 工具运行，请全部退出后再部署 / Programs or Wine tools are still active in this bottle; close them before deployment") }
        waiter.waitUntilExit()
        guard waiter.terminationStatus == 0 else { throw AppFailure("无法确认 Windows 容器已停止 / Could not confirm that the Windows bottle has stopped") }
    }
    private static func inventory(target: PatchWindowsTarget, appID: Int, paths: AppPaths, helper: URL, modules: [URL]) async throws -> Response {
        guard FileStore.fm.fileExists(atPath: helper.path) else { throw AppFailure("缺少 Windows 加载检查助手 / Windows module-check helper is missing") }
        var launch = try target.launch(appID: appID, command: helper.path, paths: paths)
        let folder = paths.cache.appendingPathComponent("PatchLoadChecks/\(UUID())")
        try FileStore.fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileStore.fm.removeItem(at: folder) }
        let request = folder.appendingPathComponent("request.json"), response = folder.appendingPathComponent("response.json"), nonce = UUID().uuidString
        try FileStore.json(Request(nonce: nonce, executable: WineLaunch.windowsPath(target.executable), modules: modules.map { try WineLaunch.windowsPath($0.path) }), to: request)
        launch.arguments += [try WineLaunch.windowsPath(request.path), try WineLaunch.windowsPath(response.path)]
        let process = try launch.launch(log: folder.appendingPathComponent("probe.log"))
        defer { if process.isRunning { process.terminate() } }
        let end = Date().addingTimeInterval(45)
        while process.isRunning && Date() < end { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100)) }
        guard !process.isRunning else { throw AppFailure("加载检查超时，未确认生效 / Module check timed out; loading remains unverified") }
        process.waitUntilExit()
        let result = try FileStore.decode(Response.self, at: response)
        guard process.terminationStatus == 0, result.ok, result.complete, result.nonce == nonce, let _ = result.processes else { throw AppFailure(result.error ?? "进程清单不完整，未确认加载 / Incomplete process inventory; loading unverified") }
        return result
    }
    /// Observes modules of an already-running exact game executable. Never launches a game,
    /// loads a patch into it, writes its memory, or calls Steam APIs.
    public static func check(_ receipt: PatchReceipt, paths: AppPaths, helper: URL) async throws -> PatchLoadCheck {
        guard !receipt.restored, UUID(uuidString: receipt.id) != nil, let target = receipt.windowsTarget, let gameHash = receipt.executableSHA256 else { throw AppFailure("旧部署缺少平台信息，请还原后重新预览部署 / Legacy deployment has no target identity; restore and preview again") }
        let root = URL(fileURLWithPath: receipt.gameRoot)
        guard target.executable.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw AppFailure("游戏程序超出部署范围 / Game executable is outside deployment scope") }
        let modules = receipt.deployed.keys.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "dll" }.sorted()
        guard !modules.isEmpty, modules.count <= 512 else { throw AppFailure("此补丁没有可检查的 DLL，或数量超过限制；不宣称已加载 / No DLLs to observe or too many modules; loading is unverified") }
        func unchanged() throws {
            guard FileStore.hash(try FileStore.read(URL(fileURLWithPath: target.executable))) == gameHash else { throw AppFailure("游戏程序已改变，请重新预览 / Game executable changed; preview again") }
            for relative in receipt.deployed.keys {
                guard FileStore.hash(try FileStore.read(GamePatches.target(relative, root: root))) == receipt.deployed[relative] else { throw AppFailure("补丁文件已改变，无法确认加载身份 / Patch files changed; module identity cannot be verified") }
            }
        }
        try unchanged()
        let result = try await inventory(target: target, appID: receipt.appID, paths: paths, helper: helper, modules: modules.map { try GamePatches.target($0, root: root) })
        let games = result.processes!
        try unchanged(); _ = try target.launch(appID: receipt.appID, command: helper.path, paths: paths)
        let check: PatchLoadCheck
        if games.isEmpty {
            check = PatchLoadCheck(state: .notRunning, date: Date(), processID: nil, loaded: [], missing: modules, detail: "没有观察到选定游戏进程；请自行启动游戏后检查 / Selected game process not observed; launch it yourself before checking")
        } else if games.count != 1 {
            check = PatchLoadCheck(state: .inconclusive, date: Date(), processID: nil, loaded: [], missing: modules, detail: "有多个相同游戏进程，无法唯一确认 / Multiple matching game processes; identity is ambiguous")
        } else {
            let game = games[0]
            guard game.pid > 0, UInt64(game.created).map({ $0 > 0 }) == true, game.loaded.count == modules.count else { throw AppFailure("模块检查响应无效 / Invalid module inventory response") }
            let start = Date(timeIntervalSince1970: Double(game.created)! / 10_000_000 - 11_644_473_600)
            guard start >= receipt.date else { throw AppFailure("游戏进程早于本次部署，请先关闭并自行重新启动后再检查 / Game predates deployment; close and relaunch it yourself before checking") }
            let loaded = modules.indices.filter { game.loaded[$0] }.map { modules[$0] }, missing = modules.indices.filter { !game.loaded[$0] }.map { modules[$0] }
            check = PatchLoadCheck(state: loaded.isEmpty ? .notLoaded : missing.isEmpty ? .loaded : .partial, date: Date(), processID: game.pid, loaded: loaded, missing: missing,
                detail: "仅验证此刻此进程的 DLL 文件身份；不代表联机成功或补丁功能有效 / Observes DLL file identity in this process now; does not verify multiplayer or patch effects")
        }
        try FileStore.json(check, to: paths.data.appendingPathComponent("PatchChecks/\(receipt.id).json"))
        return check
    }
}
