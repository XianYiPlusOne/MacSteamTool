import Foundation

/// Only future library transactions enqueue work. Existing games are never
/// swept into statistics sync. Schema fetching is read-only; activation waits
/// for Steam to exit so an active save provider cannot be invalidated mid-game.
public enum AutomaticAchievements {
    public struct Job: Codable, Equatable, Sendable {
        public var generation = UUID()
        public var attemptedAt: Date?
        public var error: String?
        public init() {}
    }
    public struct State: Codable, Equatable, Sendable {
        public var jobs: [Int: Job] = [:]
        public var completed: Set<Int> = []
        public init() {}
    }
    public struct Report: Sendable {
        public var applied: [Int] = []
        public var waitingForLogin: [Int] = []
        public var waitingForExit: [Int] = []
        public var failures: [Int: String] = [:]
    }
    public static func file(_ paths: AppPaths) -> URL {
        let scope = [paths.steam, paths.config].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.joined(separator: "\n")
        return paths.data.appendingPathComponent("Achievements/automatic-\(FileStore.hash(Data(scope.utf8)).prefix(16)).json")
    }
    private static func snapshot(_ paths: AppPaths) throws -> (State, String) {
        let url = file(paths)
        guard FileStore.fm.fileExists(atPath: url.path) else { return (State(), "missing") }
        let data = try FileStore.read(url)
        guard data.count <= 8 * 1024 * 1024 else { throw AppFailure("成就准备队列过大 / Achievement queue is too large") }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.jobs.count + state.completed.count <= 20000,
              (Array(state.jobs.keys) + Array(state.completed)).allSatisfy({ TextUtil.validID(String($0)) != nil }) else { throw AppFailure("无效成就队列 / Invalid achievement queue") }
        return (state, FileStore.hash(data))
    }
    public static func state(paths: AppPaths) throws -> State { try snapshot(paths).0 }
    private static func encode(_ state: State) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }
    public static func queueChange(paths: AppPaths, config: MacSteamConfig, apps: [Int], removing: [Int]) throws -> AutomaticCompatibility.Change? {
        let (before, hash) = try snapshot(paths); var next = before
        for id in removing { next.jobs[id] = nil }
        for id in apps where config.topLevel.contains(id) && !next.completed.contains(id) && next.jobs[id] == nil {
            next.jobs[id] = Job()
        }
        guard before != next else { return nil }
        return .init(url: file(paths), data: try encode(next), expected: hash)
    }
    private static func update(_ id: Int, generation: UUID, paths: AppPaths, complete: Bool = false, job: Job? = nil) throws {
        let (before, hash) = try snapshot(paths); var next = before
        guard next.jobs[id]?.generation == generation else { return }
        next.jobs[id] = job
        if complete { next.completed.insert(id) }
        try FileTransaction(backupRoot: paths.backups).apply([(file(paths), try encode(next))], reason: "自动成就准备 \(id)", expectations: [file(paths): hash])
    }
    public static func process(paths: AppPaths, now: Date = Date(), force: Bool = false,
                               steamRunning: () -> Bool = { SteamProcesses.isRunning },
                               fetchSchema: (Int) async throws -> Void) async throws -> Report {
        var report = Report()
        let initial = try snapshot(paths).0
        for id in initial.jobs.keys.sorted() {
            guard var job = try snapshot(paths).0.jobs[id] else { continue }
            let config = try MacSteamConfig.parse(FileStore.text(paths.config))
            guard config.topLevel.contains(id) else { try update(id, generation: job.generation, paths: paths); continue }
            if AchievementRepair.enabled(appID: id, paths: paths) {
                try update(id, generation: job.generation, paths: paths, complete: true); continue
            }
            if !AchievementRepair.schemaAvailable(appID: id, paths: paths) {
                guard steamRunning() else { report.waitingForLogin.append(id); continue }
                if !force, let attempted = job.attemptedAt, now.timeIntervalSince(attempted) < 3600 {
                    report.failures[id] = job.error ?? "等待重试 / Waiting to retry"; continue
                }
                do {
                    try await fetchSchema(id)
                    try Task.checkCancellation()
                    guard AchievementRepair.schemaAvailable(appID: id, paths: paths) else { throw AppFailure("未取得成就定义 / Achievement definitions unavailable") }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    job.attemptedAt = now; job.error = error.localizedDescription
                    try update(id, generation: job.generation, paths: paths, job: job)
                    report.failures[id] = error.localizedDescription; continue
                }
            }
            // The user can disable/remove/reimport the game while fetching.
            guard try snapshot(paths).0.jobs[id]?.generation == job.generation else { continue }
            guard steamRunning() == false else { report.waitingForExit.append(id); continue }
            do {
                try AchievementRepair.enable(appID: id, paths: paths) {
                    guard !steamRunning(), try snapshot(paths).0.jobs[id]?.generation == job.generation else {
                        throw AppFailure("Steam 或准备队列已变化，等待重试 / Steam or the preparation queue changed; waiting to retry")
                    }
                }
                try update(id, generation: job.generation, paths: paths, complete: true)
                report.applied.append(id)
            } catch { report.failures[id] = error.localizedDescription }
        }
        return report
    }
}
