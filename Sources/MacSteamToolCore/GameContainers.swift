import Foundation
import Darwin

public enum ContainerRuntime: String, Sendable, CaseIterable {
    case crossOver = "crossover", managedWine = "wine", localWine = "local-wine"

    public var subdirectory: String {
        switch self {
        case .crossOver: return ""
        case .managedWine: return "fluent-free"
        case .localWine: return LocalWine.prefixDirectory
        }
    }
    func root(in directory: URL) -> URL {
        subdirectory.isEmpty ? directory : directory.appendingPathComponent(subdirectory)
    }
}

public struct GameContainer: Identifiable, Sendable, Hashable {
    public let appID: Int
    public let library: URL
    public let runtime: ContainerRuntime
    public var isWine: Bool { runtime != .crossOver }
    public var id: String { prefix.path }
    public var root: URL {
        let base = library.appendingPathComponent("steamapps/compatdata/\(appID)")
        return runtime.root(in: base)
    }
    public var prefix: URL { root.appendingPathComponent("pfx") }
    public var exists: Bool { FileStore.fm.fileExists(atPath: prefix.path) }
    public var ready: Bool { ["user.reg", "system.reg", "drive_c"].allSatisfy { FileStore.fm.fileExists(atPath: prefix.appendingPathComponent($0).path) } }
    public init(appID: Int, library: URL, runtime: ContainerRuntime) { self.appID = appID; self.library = library; self.runtime = runtime }
    public init(appID: Int, library: URL, isWine: Bool) { self.init(appID: appID, library: library, runtime: isWine ? .managedWine : .crossOver) }
}

public struct ContainerBackend: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let build: String
    public let flavor: String
    public var runtime: ContainerRuntime {
        switch id {
        case FreeRuntime.toolID: return .managedWine
        case LocalWine.toolID: return .localWine
        default: return .crossOver
        }
    }
    public var isWine: Bool { runtime != .crossOver }
}

public struct ContainerBackup: Codable, Identifiable, Sendable {
    public let id: String
    public let appID: Int
    public let library: String
    public let isWine: Bool
    public let created: Date
    public let metadata: [String: Data]
    public var reason: String? = nil
    var profile: ContainerProfiles.Record? = nil
    // Receipts predating standalone Wine stored just the managed-Wine flag.
    var localWine: Bool? = nil
    public var runtime: ContainerRuntime { localWine == true ? .localWine : (isWine ? .managedWine : .crossOver) }
}

/// Manages only per-game prefixes. Both backends remain visible regardless of
/// the active Steam mapping. Game installation files are never backup targets.
public enum GameContainers {
    private static func gameRoot(_ container: GameContainer) -> URL {
        GameContainer(appID: container.appID, library: container.library, isWine: false).root
    }
    static let metadataNames = ["notproton-build", "notproton-msync", "notproton-session.env"]
    public static func all(_ paths: AppPaths) -> [GameContainer] {
        SteamLibrary.libraries(paths).flatMap { library in
            FileStore.files(library.appendingPathComponent("steamapps/compatdata")).flatMap { root -> [GameContainer] in
                guard let id = TextUtil.validID(root.lastPathComponent) else { return [] }
                return ContainerRuntime.allCases.map { GameContainer(appID: id, library: library, runtime: $0) }.filter { $0.exists }
            }
        }.sorted { ($0.appID, $0.id) < ($1.appID, $1.id) }
    }
    public static func recoverable(_ paths: AppPaths) -> [GameContainer] {
        var seen = Set<String>()
        return FileStore.files(paths.data.appendingPathComponent("ContainerBackups")).compactMap { folder in
            guard let item = try? FileStore.decode(ContainerBackup.self, at: folder.appendingPathComponent("receipt.json")), item.id == folder.lastPathComponent, UUID(uuidString: item.id) != nil else { return nil }
            let container = GameContainer(appID: item.appID, library: URL(fileURLWithPath: item.library), runtime: item.runtime)
            guard (try? validate(container, paths: paths)) != nil, !container.exists, matchesProfile(item, container: container), seen.insert(container.id).inserted else { return nil }
            return container
        }
    }
    public static func backends(_ paths: AppPaths) throws -> [ContainerBackend] {
        let tools = try SteamCompatibility.tools(paths: paths)
        let rows = ((try? FileStore.text(paths.notProton.appendingPathComponent("tools"))) ?? "").split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        return tools.compactMap { tool in
            if tool.id == LocalWine.toolID, let wine = LocalWine.registered(paths) {
                return ContainerBackend(id: tool.id, name: tool.name, build: wine.path, flavor: "wine")
            }
            if tool.id == FreeRuntime.toolID, FreeRuntime.installedRoot(paths) != nil {
                return ContainerBackend(id: tool.id, name: "Wine", build: FreeRuntime.release, flavor: "wine")
            }
            guard tool.id == "notproton" || tool.id.hasPrefix("notproton-"),
                  let row = rows.first(where: { $0.count >= 3 && $0[0] == tool.id }),
                  row[1].range(of: #"^\d+(?:\.\d+){1,4}(?:-fex)?$"#, options: .regularExpression) != nil,
                  ["rosetta", "fex"].contains(row[2]) else { return nil }
            return ContainerBackend(id: tool.id, name: tool.name.replacingOccurrences(of: "NotProton", with: "CrossOver", options: .caseInsensitive), build: row[1], flavor: row[2])
        }
    }
    public static func selectedTool(appID: Int, paths: AppPaths) throws -> String? {
        let file = paths.steam.appendingPathComponent("config/config.vdf")
        guard FileStore.fm.fileExists(atPath: file.path) else { return nil }
        let data = try FileStore.read(file)
        if let mapping = try SteamCompatibility.mapping(data, appID: appID) { return mapping.string("name") }
        return try SteamCompatibility.globalTool(data)
    }
    public static func backend(for container: GameContainer, paths: AppPaths) throws -> ContainerBackend? {
        let available = try backends(paths)
        if container.isWine { return available.first(where: { $0.runtime == container.runtime }) }
        let build = (try? FileStore.text(container.root.appendingPathComponent("notproton-build")))?.components(separatedBy: .newlines).first
        // An old container without a record can use only an unambiguous runner.
        let candidates = available.filter { !$0.isWine && (build == nil || $0.build == build) }
        return candidates.count == 1 ? candidates[0] : nil
    }
    public static func validate(_ container: GameContainer, paths: AppPaths) throws {
        guard TextUtil.validID(String(container.appID)) != nil,
              SteamLibrary.libraries(paths).contains(where: { $0.standardizedFileURL == container.library.standardizedFileURL }) else {
            throw AppFailure("容器不在已登记的 Steam 游戏库中 / Container is outside registered Steam libraries")
        }
        // Allow a user-selected library volume, but reject links in the owned
        // suffix. Wine's internal dosdevices links are preserved as links.
        let base = container.library.resolvingSymlinksInPath()
        let suffix = "steamapps/compatdata/\(container.appID)/" + container.runtime.subdirectory
        var path = base
        for part in (suffix + "/pfx").split(separator: "/") {
            path.appendPathComponent(String(part))
            if let info = try? FileStore.fm.attributesOfItem(atPath: path.path), info[.type] as? FileAttributeType == .typeSymbolicLink {
                throw AppFailure("容器路径包含符号链接，未执行修改 / Container path contains a symbolic link")
            }
        }
        for name in metadataNames {
            if let info = try? FileStore.fm.attributesOfItem(atPath: container.root.appendingPathComponent(name).path), info[.type] as? FileAttributeType != .typeRegular {
                throw AppFailure("容器记录文件无效 / Invalid container record file")
            }
        }
    }
    public static func requireIdle() throws {
        guard !SteamProcesses.isRunning else { throw AppFailure("请退出 Steam 后管理容器 / Quit Steam before managing containers") }
    }
    static func claim(_ container: GameContainer, paths: AppPaths, requireIdle: @Sendable () throws -> Void) async throws -> Int32 {
        try validate(container, paths: paths)
        return try await claimPrefix(at: container.root, requireIdle: requireIdle)
    }
    static func claimPrefix(at root: URL, requireIdle: @Sendable () throws -> Void) async throws -> Int32 {
        let prefix = root.appendingPathComponent("pfx")
        try requireIdle(); try FileStore.mkdir(root)
        let fd = open(root.appendingPathComponent(".notproton-prefix.lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppFailure("无法锁定容器 / Cannot lock container") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw AppFailure("容器正在准备或使用中 / Container is being prepared or used")
        }
        do {
            if let attributes = try? FileStore.fm.attributesOfItem(atPath: prefix.path),
               let device = attributes[.systemNumber] as? Int, let inode = attributes[.systemFileNumber] as? Int {
                let server = "/tmp/.wine-\(getuid())/server-\(String(device, radix: 16))-\(String(inode, radix: 16))"
                if FileStore.fm.fileExists(atPath: server) {
                    let (status, output) = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "+D", server])
                    guard status == 1, output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AppFailure("此容器仍有游戏或 Wine 工具运行，请先关闭 / Close this container's games and Wine tools first")
                    }
                }
            }
            try requireIdle(); return fd
        } catch { release(fd); throw error }
    }
    static func release(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
    /// Hold every affected prefix lock through backup and removal, including
    /// inactive backends. Snapshots preserve registry-based saves as well.
    public static func protectingRemoval(_ containers: [GameContainer], paths: AppPaths,
        requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle,
        backupReason: String = "before-uninstall", perform: () throws -> Void) async throws {
        var locks: [Int32] = []
        defer { for fd in locks.reversed() { release(fd) } }
        for container in containers.sorted(by: { $0.id < $1.id }) {
            locks.append(try await claim(container, paths: paths, requireIdle: requireIdle))
        }
        for container in containers { _ = try snapshot(container, paths: paths, requireIdle: requireIdle, reason: backupReason) }
        try requireIdle()
        try perform()
    }
    public static func create(_ container: GameContainer, backend: ContainerBackend, paths: AppPaths, requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle) async throws {
        guard backend.runtime == container.runtime else { throw AppFailure("容器与运行器不匹配 / Container backend mismatch") }
        let fd = try await claim(container, paths: paths, requireIdle: requireIdle); defer { release(fd) }
        guard !container.exists else { throw AppFailure("此游戏已有该兼容层的容器 / This container already exists") }
        let stage = container.root.appendingPathComponent(".pfx-creating-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: stage) }
        try await initializePrefix(stage, appID: container.appID, backend: backend, paths: paths, log: logURL(container, paths: paths))
        try requireIdle(); try validate(container, paths: paths)
        let previousMetadata = try metadata(container)
        do {
            try recordBackend(backend, in: container.root)
            try FileStore.fm.moveItem(at: stage, to: container.prefix)
        } catch { try? writeMetadata(previousMetadata, container: container); throw error }
    }
    static func recordBackend(_ backend: ContainerBackend, in root: URL) throws {
        if !backend.isWine {
            try FileStore.write(Data("\(backend.build)\n\(backend.flavor == "fex" ? "FEX" : "Rosetta")\n".utf8), to: root.appendingPathComponent("notproton-build"))
        }
    }
    static func initializePrefix(_ stage: URL, appID: Int, backend: ContainerBackend, paths: AppPaths, log: URL) async throws {
        guard try backends(paths).contains(where: { $0.id == backend.id && $0.build == backend.build }) else {
            throw AppFailure("所选运行器尚未就绪 / Selected runner is unavailable")
        }
        // Pre-create isolated user folders so Wine does not link host Documents.
        for folder in ["Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos", "AppData/Local", "AppData/Roaming"] {
            try FileStore.mkdir(stage.appendingPathComponent("drive_c/users/steamuser/" + folder))
        }
        try FileStore.fm.createSymbolicLink(atPath: stage.appendingPathComponent("drive_c/users/crossover").path, withDestinationPath: "steamuser")
        var launch = try WineLaunch.prepare(appID: appID, command: "wineboot", prefix: stage, paths: paths,
                                           buildRecord: [backend.build, backend.flavor == "fex" ? "FEX" : "Rosetta"])
        launch.arguments = ["wineboot", "--init"]
        let (code, output) = try await ProcessRunner.run(launch.executable, launch.arguments, environment: launch.environment)
        try FileStore.write(Data(output.utf8), to: log)
        if let server = launch.environment["WINESERVER"] {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: server), ["-k"], environment: launch.environment)
            _ = try await ProcessRunner.run(URL(fileURLWithPath: server), ["-w"], environment: launch.environment)
        }
        guard code == 0, ["system.reg", "user.reg"].allSatisfy({ FileStore.fm.fileExists(atPath: stage.appendingPathComponent($0).path) }) else { throw AppFailure("容器创建失败，原有环境未修改；请查看容器日志 / Container creation failed; existing environments are unchanged. See container log") }
    }
    public static func logURL(_ container: GameContainer, paths: AppPaths) -> URL {
        if let record = try? ContainerProfiles.read(gameRoot(container)), record.name != nil {
            return paths.data.appendingPathComponent("Logs/containers/\(record.id.uuidString).log")
        }
        return paths.data.appendingPathComponent("Logs/containers/\(container.appID)-\(container.runtime.rawValue).log")
    }
    public static func launch(_ container: GameContainer, command: String, paths: AppPaths, requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle) async throws -> Process {
        let fd = try await claim(container, paths: paths, requireIdle: requireIdle)
        do {
            guard container.ready, try backend(for: container, paths: paths) != nil else { throw AppFailure("容器或对应兼容层尚未就绪 / Container or its backend is not ready") }
            let launch = try WineLaunch.prepare(appID: container.appID, command: command, prefix: container.prefix, paths: paths)
            let log = logURL(container, paths: paths)
            try FileStore.mkdir(log.deletingLastPathComponent())
            if !FileStore.fm.fileExists(atPath: log.path) { try Data().write(to: log) }
            let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
            let process = Process(); process.executableURL = launch.executable; process.arguments = launch.arguments
            process.environment = launch.environment; process.currentDirectoryURL = container.prefix
            process.standardOutput = handle; process.standardError = handle
            process.terminationHandler = { _ in try? handle.close(); release(fd) }
            do { try process.run() } catch { try? handle.close(); throw error }
            return process
        } catch { release(fd); throw error }
    }
    public static func removalBackups(appIDs: [Int], paths: AppPaths) -> [ContainerBackup] {
        var seen = Set<String>()
        return FileStore.files(paths.data.appendingPathComponent("ContainerBackups")).compactMap { folder -> ContainerBackup? in
            guard let item = try? FileStore.decode(ContainerBackup.self, at: folder.appendingPathComponent("receipt.json")),
                  item.reason == "before-uninstall", item.id == folder.lastPathComponent, UUID(uuidString: item.id) != nil,
                  appIDs.contains(item.appID) else { return nil }
            return item
        }.sorted { $0.created > $1.created }.filter { seen.insert("\($0.appID):\($0.runtime.rawValue):\($0.profile?.id.uuidString ?? "")").inserted }
    }
    private static func matchesProfile(_ backup: ContainerBackup, container: GameContainer) -> Bool {
        do {
            let current = try ContainerProfiles.read(gameRoot(container))
            if current?.name == nil && backup.profile?.name == nil { return true }
            return current?.id == backup.profile?.id
        } catch { return false }
    }
    public static func backups(_ container: GameContainer, paths: AppPaths) -> [ContainerBackup] {
        FileStore.files(paths.data.appendingPathComponent("ContainerBackups")).compactMap { folder in
            guard let item = try? FileStore.decode(ContainerBackup.self, at: folder.appendingPathComponent("receipt.json")),
                  item.id == folder.lastPathComponent, item.appID == container.appID, item.runtime == container.runtime,
                  item.library == container.library.path, matchesProfile(item, container: container) else { return nil }
            return item
        }.sorted { $0.created > $1.created }
    }
    private static func metadata(_ container: GameContainer) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in metadataNames {
            let path = container.root.appendingPathComponent(name)
            if FileStore.fm.fileExists(atPath: path.path) { result[name] = try FileStore.read(path) }
        }
        return result
    }
    private static func writeMetadata(_ data: [String: Data], container: GameContainer) throws {
        for name in metadataNames {
            let path = container.root.appendingPathComponent(name)
            if let bytes = data[name] { try FileStore.write(bytes, to: path) }
            else if FileStore.fm.fileExists(atPath: path.path) { try FileStore.fm.removeItem(at: path) }
        }
    }
    private static func snapshot(_ container: GameContainer, paths: AppPaths, requireIdle: @Sendable () throws -> Void, reason: String? = nil) throws -> ContainerBackup {
        guard container.exists else { throw AppFailure("容器不存在 / Container does not exist") }
        let item = ContainerBackup(id: UUID().uuidString, appID: container.appID, library: container.library.path, isWine: container.isWine, created: Date(), metadata: try metadata(container), reason: reason, profile: try ContainerProfiles.read(gameRoot(container)), localWine: container.runtime == .localWine ? true : nil)
        let base = paths.data.appendingPathComponent("ContainerBackups"), stage = base.appendingPathComponent(".stage-" + item.id)
        try FileStore.mkdir(stage); defer { try? FileStore.fm.removeItem(at: stage) }
        try FileStore.fm.copyItem(at: container.prefix, to: stage.appendingPathComponent("pfx"))
        try FileStore.json(item, to: stage.appendingPathComponent("receipt.json"))
        try requireIdle()
        try FileStore.fm.moveItem(at: stage, to: base.appendingPathComponent(item.id))
        return item
    }
    @discardableResult public static func backup(_ container: GameContainer, paths: AppPaths, requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle) async throws -> ContainerBackup {
        let fd = try await claim(container, paths: paths, requireIdle: requireIdle); defer { release(fd) }
        return try snapshot(container, paths: paths, requireIdle: requireIdle)
    }
    @discardableResult public static func remove(_ container: GameContainer, paths: AppPaths, requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle) async throws -> ContainerBackup {
        let fd = try await claim(container, paths: paths, requireIdle: requireIdle); defer { release(fd) }
        let copy = try snapshot(container, paths: paths, requireIdle: requireIdle)
        try requireIdle(); try validate(container, paths: paths)
        try FileStore.fm.removeItem(at: container.prefix)
        return copy
    }
    public static func restore(_ item: ContainerBackup, to container: GameContainer, paths: AppPaths, relocating: Bool = false, requireIdle: @escaping @Sendable () throws -> Void = GameContainers.requireIdle) async throws {
        let fd = try await claim(container, paths: paths, requireIdle: requireIdle); defer { release(fd) }
        guard item.appID == container.appID, item.runtime == container.runtime, UUID(uuidString: item.id) != nil else { throw AppFailure("备份与容器不匹配 / Backup does not match this container") }
        let backup = paths.data.appendingPathComponent("ContainerBackups/\(item.id)")
        let receipt = try FileStore.decode(ContainerBackup.self, at: backup.appendingPathComponent("receipt.json"))
        guard receipt.appID == container.appID, receipt.runtime == container.runtime, receipt.id == item.id,
              receipt.library == item.library, relocating || receipt.library == container.library.path else { throw AppFailure("容器备份记录不匹配 / Container backup receipt mismatch") }
        let root = gameRoot(container)
        let adopting = !matchesProfile(receipt, container: container)
        if adopting {
            guard relocating, receipt.reason == "before-uninstall", try ContainerProfiles.read(root) == nil,
                  !container.exists, let profile = receipt.profile,
                  !(try ContainerProfiles(appID: container.appID, library: container.library, paths: paths).list()).contains(where: { $0.id == profile.id }) else {
                throw AppFailure("请切换到此备份所属的容器 / Switch to the container that owns this backup")
            }
        }
        guard try backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try backup.appendingPathComponent("pfx").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("备份目录无效 / Invalid backup directory") }
        if container.exists { _ = try snapshot(container, paths: paths, requireIdle: requireIdle) }
        let stage = container.root.appendingPathComponent(".pfx-restoring-\(UUID().uuidString)"), previous = container.root.appendingPathComponent(".pfx-previous-\(UUID().uuidString)")
        defer { try? FileStore.fm.removeItem(at: stage) }
        try FileStore.fm.copyItem(at: backup.appendingPathComponent("pfx"), to: stage)
        let oldMetadata = try metadata(container), existed = container.exists
        try requireIdle(); try validate(container, paths: paths)
        if existed { try FileStore.fm.moveItem(at: container.prefix, to: previous) }
        do {
            try FileStore.fm.moveItem(at: stage, to: container.prefix)
            try writeMetadata(receipt.metadata, container: container)
            if adopting, let profile = receipt.profile { try FileStore.json(profile, to: root.appendingPathComponent(ContainerProfiles.marker)) }
        } catch {
            try? FileStore.fm.removeItem(at: container.prefix)
            if existed { try? FileStore.fm.moveItem(at: previous, to: container.prefix) }
            try? writeMetadata(oldMetadata, container: container)
            throw error
        }
        try? FileStore.fm.removeItem(at: previous)
    }
}
