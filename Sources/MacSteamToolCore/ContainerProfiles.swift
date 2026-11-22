import Foundation
import Darwin

/// A profile is one game's complete compatdata directory, including NotProton's
/// runner record and either backend's prefix. Steam always opens its usual path.
public struct ContainerProfile: Identifiable, Sendable {
    public let id: UUID?
    public let name: String?
    public let tool: String?
    public let directory: URL
    public let active: Bool
}

public struct ContainerProfiles: Sendable {
    struct Record: Codable, Sendable {
        let id: UUID
        let name: String?
        let tool: String?
    }

    private let container: GameContainer
    private let paths: AppPaths
    private let storage: URL
    static let marker = ".fluent-container.json"

    private struct SwitchIntent: Codable {
        let previous: UUID
        let next: UUID
        let slot: UUID
        let previousTool: String?
        let nextTool: String?
    }
    private var intentFile: URL { storage.appendingPathComponent(".switch.json") }

    public init(appID: Int, library: URL, paths: AppPaths) {
        self.paths = paths
        container = GameContainer(appID: appID, library: library, isWine: false)
        storage = library.resolvingSymlinksInPath().appendingPathComponent("steamapps/fluent-containers/\(appID)")
    }

    static func read(_ dir: URL) throws -> Record? {
        let file = dir.appendingPathComponent(Self.marker)
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw AppFailure("容器记录是符号链接 / Invalid container record") }
        guard FileStore.fm.fileExists(atPath: file.path) else { return nil }
        return try FileStore.decode(Record.self, at: file)
    }

    public func list() throws -> [ContainerProfile] {
        try GameContainers.validate(container, paths: paths)
        try GameRemoval.noLinks(storage)
        let current = try Self.read(container.root)
        var profiles = [ContainerProfile(id: current?.id, name: current?.name,
            tool: try GameContainers.selectedTool(appID: container.appID, paths: paths),
            directory: container.root, active: true)]
        for slot in FileStore.files(storage) where UUID(uuidString: slot.lastPathComponent) != nil {
            try GameRemoval.noLinks(slot)
            guard let record = try Self.read(slot) else { throw AppFailure("缺少容器记录 / Missing container record: \(slot.path)") }
            profiles.append(ContainerProfile(id: record.id, name: record.name, tool: record.tool, directory: slot, active: false))
        }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw AppFailure("容器标识重复 / Duplicate container identity") }
        return [profiles[0]] + profiles.dropFirst().sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }

    private func lock() throws -> Int32 {
        try GameContainers.validate(container, paths: paths)
        try GameRemoval.noLinks(storage)
        try FileStore.mkdir(storage)
        let fd = open(storage.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw AppFailure("此游戏的容器正在操作中 / Another operation is managing this game's containers")
        }
        return fd
    }

    @discardableResult public func create(name: String, backend: ContainerBackend) async throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppFailure("请输入 1 到 80 个字符的容器名称 / Enter a container name of 1 to 80 characters")
        }
        let fd = try lock(); defer { GameContainers.release(fd) }
        let reserved = ["默认容器", "Default container"] + (try list()).compactMap(\.name)
        guard !reserved.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppFailure("此游戏已有同名容器 / This game already has a container with that name")
        }
        let id = UUID(), slot = storage.appendingPathComponent(id.uuidString)
        let stage = storage.appendingPathComponent(".creating-" + id.uuidString)
        defer { try? FileStore.fm.removeItem(at: stage) }
        let root = backend.isWine ? stage.appendingPathComponent("fluent-free") : stage
        let log = paths.data.appendingPathComponent("Logs/containers/\(id.uuidString).log")
        try await GameContainers.initializePrefix(root.appendingPathComponent("pfx"), appID: container.appID, backend: backend, paths: paths, log: log)
        try GameContainers.recordBackend(backend, in: root)
        try FileStore.json(Record(id: id, name: name, tool: backend.id), to: stage.appendingPathComponent(Self.marker))
        try FileStore.fm.moveItem(at: stage, to: slot)
        return id
    }

    public func moveToTrash(_ id: UUID) async throws {
        let fd = try lock(); defer { GameContainers.release(fd) }
        guard !needsRecovery, let profile = try list().first(where: { $0.id == id }), !profile.active, profile.name != nil else {
            throw AppFailure("请先切换到另一个容器 / Switch to another container first")
        }
        var locks: [Int32] = []
        defer { locks.reversed().forEach(GameContainers.release) }
        for root in [profile.directory, profile.directory.appendingPathComponent("fluent-free")] {
            try GameRemoval.noLinks(root.appendingPathComponent("pfx"))
            if FileStore.fm.fileExists(atPath: root.path) {
                locks.append(try await GameContainers.claimPrefix(at: root, requireIdle: {}))
            }
        }
        try FileStore.fm.trashItem(at: profile.directory, resultingItemURL: nil)
    }

    /// RENAME_SWAP exchanges both complete environments in one filesystem
    /// operation. Their identities travel with them, so no active index can go stale.
    public func activate(_ id: UUID, requireIdle: @escaping @Sendable () throws -> Void = { try GameContainers.requireIdle() }) async throws {
        let fd = try lock(); defer { GameContainers.release(fd) }
        try requireIdle()
        try await recoverInterruptedSwitch(requireIdle: requireIdle)
        let profiles = try list()
        guard let target = profiles.first(where: { $0.id == id }) else { throw AppFailure("容器已变化，请刷新 / Container changed. Refresh and retry.") }
        if target.active { return }
        if let tool = target.tool, !tool.isEmpty, !(try SteamCompatibility.tools(paths: paths)).contains(where: { $0.id == tool }) {
            throw AppFailure("请先准备此容器使用的运行器 / Install this container's runner first")
        }
        let config = paths.steam.appendingPathComponent("config/config.vdf")
        let before = try FileStore.read(config)
        let priorMapping = try SteamCompatibility.mapping(before, appID: container.appID)?.string("name")
        let prior = profiles[0]
        let previousID = prior.id ?? UUID()
        let priorTool = prior.name == nil ? priorMapping : prior.tool
        guard let slot = UUID(uuidString: target.directory.lastPathComponent) else { throw AppFailure("容器位置已变化 / Container location changed") }
        try await withPrefixLocks(target.directory, requireIdle: requireIdle) {
            try FileStore.json(Record(id: previousID, name: prior.name, tool: priorTool), to: container.root.appendingPathComponent(Self.marker))
            let changesMapping = target.tool != priorMapping && (target.tool == nil || target.tool != prior.tool)
            if changesMapping {
                try FileStore.json(SwitchIntent(previous: previousID, next: id, slot: slot, previousTool: priorMapping, nextTool: target.tool), to: intentFile)
            }
            try requireIdle()
            try exchange(with: target.directory)
            do {
                if changesMapping {
                    _ = try SteamCompatibility.save(paths: paths, appID: container.appID, tool: target.tool, requireIdle: requireIdle)
                }
            } catch {
                try exchange(with: target.directory)
                if changesMapping { try FileStore.fm.removeItem(at: intentFile) }
                throw error
            }
            if changesMapping { try FileStore.fm.removeItem(at: intentFile) }
        }
    }

    private func exchange(with slot: URL) throws {
        guard renamex_np(container.root.path, slot.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func withPrefixLocks(_ slot: URL, requireIdle: @Sendable () throws -> Void, perform: () throws -> Void) async throws {
        var locks: [Int32] = []
        defer { for fd in locks.reversed() { GameContainers.release(fd) } }
        for wine in [false, true] {
            let current = GameContainer(appID: container.appID, library: container.library, isWine: wine)
            if !wine || current.exists { locks.append(try await GameContainers.claim(current, paths: paths, requireIdle: requireIdle)) }
            let root = wine ? slot.appendingPathComponent("fluent-free") : slot
            try GameRemoval.noLinks(root.appendingPathComponent("pfx"))
            if !wine || FileStore.fm.fileExists(atPath: root.path) {
                locks.append(try await GameContainers.claimPrefix(at: root, requireIdle: requireIdle))
            }
        }
        try requireIdle(); try perform()
    }

    public var needsRecovery: Bool { FileStore.fm.fileExists(atPath: intentFile.path) }

    public func recover(requireIdle: @escaping @Sendable () throws -> Void = { try GameContainers.requireIdle() }) async throws {
        guard needsRecovery else { return }
        let fd = try lock(); defer { GameContainers.release(fd) }
        try await recoverInterruptedSwitch(requireIdle: requireIdle)
    }

    private func recoverInterruptedSwitch(requireIdle: @Sendable () throws -> Void) async throws {
        guard needsRecovery else { return }
        try requireIdle()
        try GameRemoval.noLinks(intentFile)
        let intent = try FileStore.decode(SwitchIntent.self, at: intentFile)
        let slot = storage.appendingPathComponent(intent.slot.uuidString)
        try GameRemoval.noLinks(slot)
        let active = try Self.read(container.root)?.id, inactive = try Self.read(slot)?.id
        guard Set([active, inactive]) == Set([intent.previous, intent.next]) else { throw AppFailure("容器目录已改变，无法自动恢复切换 / Cannot recover a switch after its directories changed") }
        if active == intent.next {
            let config = try FileStore.read(paths.steam.appendingPathComponent("config/config.vdf"))
            let tool = try SteamCompatibility.mapping(config, appID: container.appID)?.string("name")
            if tool != intent.nextTool && tool == intent.previousTool {
                try await withPrefixLocks(slot, requireIdle: requireIdle) { try exchange(with: slot) }
            }
        }
        try FileStore.fm.removeItem(at: intentFile)
    }
}
