import Foundation

/// Persisted import work, scoped to the selected Steam installation. No keys or
/// tickets are stored here; the signature invalidates decisions when content changes.
public enum AutomaticCompatibility {
    public enum Decision: String, Codable, Sendable { case windowsOnly, nativeAvailable, unknown }
    public struct Job: Codable, Equatable, Sendable {
        public var signature: String
        public var decision: Decision?
        public var checkedAt: Date?
    }
    public struct State: Codable, Equatable, Sendable {
        public var jobs: [Int: Job] = [:]
        public var manual: Set<Int> = []
        public init() {}
    }
    public struct Change {
        public let url: URL
        public let data: Data
        public let expected: String
    }
    public struct Report: Sendable {
        public var applied: [Int] = []
        public var waitingForSteam: [Int] = []
        public var waitingForTool: [Int] = []
        public var unresolved: [Int] = []
    }
    public static func file(_ paths: AppPaths) -> URL {
        let scope = FileStore.hash(Data(paths.steam.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        return paths.data.appendingPathComponent("Compatibility/automatic-\(scope.prefix(16)).json")
    }
    private static func snapshot(_ paths: AppPaths) throws -> (State, String) {
        let url = file(paths)
        guard FileStore.fm.fileExists(atPath: url.path) else { return (State(), "missing") }
        let bytes = try FileStore.read(url)
        guard bytes.count <= 8 * 1024 * 1024 else { throw AppFailure("自动运行器队列过大 / Automatic runtime queue is too large") }
        let state = try JSONDecoder().decode(State.self, from: bytes)
        guard state.jobs.count <= 10000, state.jobs.keys.allSatisfy({ TextUtil.validID(String($0)) != nil }) else { throw AppFailure("自动运行器队列无效 / Invalid automatic runtime queue") }
        return (state, FileStore.hash(bytes))
    }
    public static func state(paths: AppPaths) throws -> State { try snapshot(paths).0 }
    private static func encoded(_ value: State) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
    private static func signature(_ config: MacSteamConfig, _ id: Int) -> String {
        let values = (config.keys[id] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        return FileStore.hash(Data(values.utf8))
    }
    /// Called inside the library transaction, so failed/cancelled imports never
    /// leave automatic work behind. Reimports use the final merged depot set.
    public static func queueChange(paths: AppPaths, config: MacSteamConfig, apps: [Int], removing: [Int] = []) throws -> Change? {
        let (before, hash) = try snapshot(paths); var next = before
        for id in removing { next.jobs[id] = nil }
        for id in apps where !next.manual.contains(id) {
            next.jobs[id] = Job(signature: signature(config, id))
        }
        guard before != next else { return nil }
        return Change(url: file(paths), data: try encoded(next), expected: hash)
    }
    public static func manualChange(paths: AppPaths, appID: Int) throws -> Change {
        let (before, hash) = try snapshot(paths); var next = before
        next.manual.insert(appID); next.jobs[appID] = nil
        return Change(url: file(paths), data: try encoded(next), expected: hash)
    }
    public static func assess(info: AppInfo, available: Set<Int>) -> Decision {
        // Exclude Workshop keys, DLC and unknown depots; unknown primary content
        // prevents an automatic guess. Shared depots inherit the app's OS list.
        let base = info.depots.filter { $0.dlc == nil && !info.dlc.contains($0.id) }
        let known = Set((info.depots + (info.sharedDepots ?? [])).map(\.id)).union(info.dlc).union([info.id])
        guard available.subtracting(known).isEmpty else { return .unknown }
        let selected = base.filter { available.contains($0.id) }
        guard !selected.isEmpty else { return .unknown }
        guard selected.allSatisfy({ (UInt64($0.manifest) ?? 0) > 0 }) else { return .unknown }
        var windows = false
        for depot in selected {
            var systems = Set(depot.os.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            if systems.isEmpty || systems.contains("all") { systems = info.platforms }
            if systems.contains("macos") { return .nativeAvailable }
            guard !systems.isEmpty, systems.isSubset(of: ["windows", "linux"]) else { return .unknown }
            windows = windows || systems.contains("windows")
        }
        return windows ? .windowsOnly : .unknown
    }
    public static func preferredTool(_ tools: [SteamCompatibility.Tool], config: Data) throws -> String? {
        let available = tools.filter { $0.id.hasPrefix("notproton-") }
        // Preserve the user's global NotProton preference when it is installed.
        if let global = try SteamCompatibility.globalTool(config), available.contains(where: { $0.id == global }) { return global }
        return available.sorted { $0.id.compare($1.id, options: [.numeric, .literal]) == .orderedDescending }.first?.id
    }
    private static func backupRoot(_ paths: AppPaths) throws -> URL {
        let url = paths.data.appendingPathComponent("CompatibilityBackups")
        try FileStore.mkdir(url); try FileStore.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private static func configSnapshot(_ paths: AppPaths) throws -> (MacSteamConfig, Data) {
        let bytes = try FileStore.read(paths.config)
        return (try MacSteamConfig.parse(String(decoding: bytes, as: UTF8.self)), bytes)
    }
    /// May resolve metadata while Steam runs. config.vdf is touched only after
    /// Steam exits, rechecking content, manual overrides and hashes at commit.
    public static func process(paths: AppPaths, force: Bool = false, now: Date = Date(),
                               steamRunning: () -> Bool = { SteamProcesses.isRunning },
                               fetch: (Int) async throws -> AppInfo) async throws -> Report {
        let initial = try snapshot(paths).0
        guard !initial.jobs.isEmpty else { return Report() }
        let steamFile = paths.steam.appendingPathComponent("config/config.vdf")
        // A first Steam launch must be allowed to create its configuration.
        guard FileStore.fm.fileExists(atPath: steamFile.path), FileStore.fm.fileExists(atPath: paths.config.path) else {
            var report = Report(); report.unresolved = initial.jobs.keys.sorted(); return report
        }
        for id in initial.jobs.keys.sorted() {
            let (before, hash) = try snapshot(paths); var next = before
            guard var job = next.jobs[id] else { continue }
            let (config, _) = try configSnapshot(paths)
            let steamBytes = try FileStore.read(steamFile)
            let existing = try SteamCompatibility.mapping(steamBytes, appID: id)
            if !config.topLevel.contains(id) || next.manual.contains(id) || existing != nil {
                next.jobs[id] = nil
            } else {
                let current = signature(config, id)
                if job.signature != current { job = Job(signature: current) }
                if job.decision == nil || ((force || now.timeIntervalSince(job.checkedAt ?? .distantPast) >= 600) && job.decision == .unknown) {
                    do {
                        let info = try await fetch(id)
                        try Task.checkCancellation()
                        guard info.id == id else { throw AppFailure("运行平台资料 AppID 不匹配 / Platform metadata AppID mismatch") }
                        job.decision = assess(info: info, available: Set((config.keys[id] ?? [:]).keys))
                    } catch is CancellationError { throw CancellationError() }
                    catch { job.decision = .unknown }
                    job.checkedAt = now
                }
                next.jobs[id] = job.decision == .nativeAvailable ? nil : job
            }
            // A user may import/remove/change this game while the request awaits.
            // Never persist a stale result over a newer queued decision.
            guard try snapshot(paths).1 == hash else { continue }
            let (fresh, _) = try configSnapshot(paths)
            if fresh.topLevel.contains(id) != config.topLevel.contains(id) || signature(fresh, id) != signature(config, id) { continue }
            if before != next {
                try FileTransaction(backupRoot: backupRoot(paths)).apply([(file(paths), try encoded(next))], reason: "自动运行平台检查 \(id)", expectations: [file(paths): hash])
            }
        }
        let (before, hash) = try snapshot(paths); var next = before
        let (config, configBytes) = try configSnapshot(paths)
        let original = try FileStore.read(steamFile); var edited = original
        let tool = try preferredTool(SteamCompatibility.tools(paths: paths), config: original)
        var report = Report()
        let running = steamRunning()
        for id in before.jobs.keys.sorted() {
            guard let job = before.jobs[id] else { continue }
            let existing = try SteamCompatibility.mapping(original, appID: id)
            if !config.topLevel.contains(id) || before.manual.contains(id) || existing != nil { next.jobs[id] = nil; continue }
            guard signature(config, id) == job.signature else { next.jobs[id] = Job(signature: signature(config, id)); report.unresolved.append(id); continue }
            guard job.decision == .windowsOnly else { report.unresolved.append(id); continue }
            guard let tool else { report.waitingForTool.append(id); continue }
            guard !running else { report.waitingForSteam.append(id); continue }
            edited = try SteamCompatibility.edit(edited, appID: id, tool: tool)
            next.jobs[id] = nil; report.applied.append(id)
        }
        if before != next || edited != original {
            var changes: [(URL, Data?)] = [(file(paths), try encoded(next))]
            if edited != original { changes.append((steamFile, edited)) }
            let editsSteam = edited != original
            try FileTransaction(backupRoot: backupRoot(paths)).apply(changes, reason: "自动选择 NotProton \(report.applied.map(String.init).joined(separator: ","))",
                expectations: [file(paths): hash, paths.config: FileStore.hash(configBytes), steamFile: FileStore.hash(original)], validate: {
                    if editsSteam && steamRunning() { throw AppFailure("Steam 已启动，自动运行器设置保留到下次退出 / Steam started; runtime changes remain queued until it exits") }
                })
        }
        return report
    }
}
