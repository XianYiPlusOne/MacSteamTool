import Foundation
import AppKit
import Darwin

public struct RuntimeStatus: Sendable {
    public var steamInstalled: Bool
    public var macSteamVersion: String
    public var notProtonVersion: String
    public var injectedLibraries: [String]
    public var missingLibraries: [String]
    public var configExists: Bool
    public var runners: [URL]
    public var prefixCount: Int
    public var build: String
    public var macSteamSignature: Bool
    public var notProtonSignature: Bool
    public var macSteamLoaded: String = ""
    public var notProtonLoaded: String = ""
    public var manifestPinsLoaded: String = ""
    public var runtimeWarnings: [String] = []
    public static var empty: Self { Self(steamInstalled: false, macSteamVersion: "—", notProtonVersion: "—", injectedLibraries: [], missingLibraries: [], configExists: false, runners: [], prefixCount: 0, build: "", macSteamSignature: false, notProtonSignature: false) }
    public var bothInjected: Bool {
        injectedLibraries.contains { $0.hasSuffix("/macsteam.dylib") } && injectedLibraries.contains { $0.hasSuffix("/notproton.dylib") } && missingLibraries.isEmpty
    }
    public static func read(_ p: AppPaths) -> Self {
        let info = (try? Data(contentsOf: p.steamApp.appendingPathComponent("Contents/Info.plist"))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let env = info["LSEnvironment"] as? [String: String] ?? [:]
        let libs = (env["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
        let runners = FileStore.files(p.notProton.appendingPathComponent("runners")).map { $0.appendingPathComponent("CrossOver") }.filter { FileStore.fm.fileExists(atPath: $0.path) }
        let version = { (url: URL) in (try? FileStore.text(url).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "—" }
        let package = p.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/package")
        var build = ""
        for name in ["steam_client_signed-2_osx.manifest", "steam_client_signed_osx.manifest", "steam_client_osx.manifest"] {
            if let text = try? FileStore.text(package.appendingPathComponent(name)),
               let match = TextUtil.matches(#"["']version["']\s+["'](\d+)["']"#, text).first {
                build = match[1]; break
            }
        }
        var result = Self(steamInstalled: FileStore.fm.fileExists(atPath: p.steamApp.path), macSteamVersion: version(p.macSteam.appendingPathComponent("dylib.version")), notProtonVersion: version(p.notProton.appendingPathComponent("dylib.version")), injectedLibraries: libs, missingLibraries: libs.filter { !FileStore.fm.fileExists(atPath: $0) }, configExists: FileStore.fm.fileExists(atPath: p.config.path), runners: runners, prefixCount: SteamLibrary.prefixes(p).count, build: build,
                    macSteamSignature: !build.isEmpty && FileStore.fm.fileExists(atPath: p.macSteam.appendingPathComponent("signatures/macos.arm64/\(build).json").path),
                    notProtonSignature: !build.isEmpty && FileStore.fm.fileExists(atPath: p.notProton.appendingPathComponent("signatures/macos.arm64/\(build).json").path))
        if let pid = SteamProcesses.pids().first {
            let mac = RuntimeEvidence.parse((try? FileStore.text(p.macSteam.appendingPathComponent("macsteam.log"))) ?? "", pid: pid)
            let np = RuntimeEvidence.parse((try? FileStore.text(p.notProton.appendingPathComponent("notproton.log"))) ?? "", pid: pid)
            result.macSteamLoaded = mac.summary; result.notProtonLoaded = np.summary
            result.manifestPinsLoaded = ((try? FileStore.text(p.data.appendingPathComponent("manifest-pins.log"))) ?? "").components(separatedBy: .newlines).last(where: { $0.hasPrefix("PID \(pid) · ") }) ?? ""
            result.runtimeWarnings = mac.warnings + np.warnings
        }
        return result
    }
}

/// Steam registers the overlay under the same bundle ID; LaunchServices may also
/// return a stale main entry with PID -1 after the bootstrapper hands off.
public enum SteamProcesses {
    public static func pids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return [] }
        return pids.prefix(min(Int(found), pids.count)).filter { pid in
            guard pid > 0 else { return false }
            var path = [CChar](repeating: 0, count: 4096 /* PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN */)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            return length > 0 && String(cString: path).hasSuffix("/steam_osx")
        }.sorted()
    }
    public static var isRunning: Bool { !pids().isEmpty }
}

public struct RuntimeEvidence: Sendable {
    public var summary: String
    public var warnings: [String]
    public static func parse(_ log: String, pid: Int32) -> Self {
        let lines = log.components(separatedBy: .newlines)
        guard let start = lines.lastIndex(where: { $0.contains("loaded into steam_osx (pid \(pid))") }) else { return Self(summary: "", warnings: []) }
        let session = lines[start...].prefix { !$0.contains("loaded into steam_osx (pid ") || $0.contains("(pid \(pid))") }
        let ready = session.filter { $0.contains("ready") && $0.contains("hooks installed") }.compactMap { TextUtil.matches(#"(\d+/\d+) hooks installed"#, $0).first?[1] }
        let signatures = session.filter { $0.contains("signatures") && $0.contains("resolved") }.compactMap { TextUtil.matches(#"(\d+/\d+)(?: signatures)? resolved"#, $0).first?[1] }
        let summary = ready.isEmpty ? "" : "PID \(pid) · \(signatures.first ?? "?") signatures · \(ready.joined(separator: " + ")) hooks"
        let warnings: [String] = Array(session.filter { $0.contains(" warn ") || $0.hasPrefix("warn ") || $0.contains(" error ") || $0.contains(" ERR ") }.suffix(6))
        return Self(summary: summary, warnings: warnings)
    }
}

public enum ProcessRunner {
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> (Int32, String) {
        try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data.suffix(1_000_000), as: UTF8.self))
        }.value
    }
}

public struct WineLaunch {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var prefix: URL
    public static func prepare(appID: Int, command: String, paths: AppPaths) throws -> Self {
        guard let prefix = SteamLibrary.prefixes(paths).first(where: { $0.id == appID })?.url else { throw AppFailure("此游戏还没有 NotProton 前缀。请先通过 Steam 成功运行一次 Windows 版本 / No NotProton prefix; first launch the Windows version through Steam") }
        let root = prefix.deletingLastPathComponent()
        let record = (try? FileStore.text(root.appendingPathComponent("notproton-build")))?.components(separatedBy: .newlines)
        let runners = RuntimeStatus.read(paths).runners
        let runner: URL
        if let build = record?.first, !build.isEmpty {
            let exact = paths.notProton.appendingPathComponent("runners/crossover-\(build)/CrossOver")
            guard FileStore.fm.fileExists(atPath: exact.path) else { throw AppFailure("该前缀使用 CrossOver / This prefix uses CrossOver \(build)，但此运行器不存在，请在 NotProton 中修复 / Runner missing; repair it in NotProton") }; runner = exact
        } else {
            guard runners.count == 1, let only = runners.first else { throw AppFailure("无法唯一确定前缀运行器，请先在 NotProton 中运行此游戏 / Cannot identify the prefix runner; launch the game in NotProton first") }; runner = only
        }
        let flavor = record?.dropFirst().joined(separator: " ").lowercased() ?? ""
        let arm = runner.appendingPathComponent("lib/wine/aarch64-unix")
        let useFEX = flavor.contains("fex")
        let unix = useFEX ? arm : runner.appendingPathComponent("lib/wine/x86_64-unix")
        let loader = useFEX ? unix.appendingPathComponent("wine.app/Contents/MacOS/wine") : unix.appendingPathComponent("wine")
        let server = runner.appendingPathComponent(useFEX ? "bin/wineserver-arm64" : "bin/wineserver")
        guard FileStore.fm.isExecutableFile(atPath: loader.path), FileStore.fm.isExecutableFile(atPath: server.path) else { throw AppFailure("NotProton 的 Wine loader / wineserver 不完整") }
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path; env["CX_ROOT"] = runner.path
        env["CX_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver").path
        env["WINELOADER"] = loader.path; env["WINESERVER"] = server.path
        env["WINEDLLPATH"] = runner.appendingPathComponent("lib/wine/x86_64-windows").path + ":" + unix.path
        // lsteamclient needs the native client directory even for tools launched
        // outside Steam. Without it, its first CreateInterface call aborts.
        let clients = [paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS"), paths.steamApp.appendingPathComponent("Contents/MacOS")]
        if let client = clients.first(where: { FileStore.fm.fileExists(atPath: $0.appendingPathComponent("steamclient.dylib").path) }) {
            env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = client.path
        }
        env["SteamAppId"] = String(appID); env["SteamGameId"] = String(appID)
        let bridge = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        if FileStore.fm.fileExists(atPath: bridge.appendingPathComponent("lsteamclient.so").path) {
            env["WINEDLLPATH"] = bridge.path + ":" + (env["WINEDLLPATH"] ?? "")
            let overrides = (env["WINEDLLOVERRIDES"] ?? "").split(separator: ";").map(String.init).filter {
                !["steamclient", "steamclient64", "lsteamclient"].contains($0.components(separatedBy: "=")[0].lowercased())
            }
            env["WINEDLLOVERRIDES"] = (overrides + ["steamclient=n", "steamclient64=n", "lsteamclient=b"]).joined(separator: ";")
        }
        env["WINEMSYNC"] = ((try? FileStore.text(root.appendingPathComponent("notproton-msync")))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1") ? "1" : "0"
        env["PATH"] = runner.appendingPathComponent("bin").path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        let arguments = command.lowercased().hasSuffix(".msi") ? ["msiexec", "/i", command] : [command]
        return Self(executable: loader, arguments: arguments, environment: env, prefix: prefix)
    }
    @discardableResult public func launch(log: URL) throws -> Process {
        try FileStore.mkdir(log.deletingLastPathComponent())
        if !FileStore.fm.fileExists(atPath: log.path) { FileStore.fm.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        let process = Process(); process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = prefix; process.standardOutput = handle; process.standardError = handle
        process.terminationHandler = { _ in try? handle.close() }
        try process.run(); return process
    }
}

public struct SteamAccount: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var persona: String
    public var recent: Bool
}
public enum Accounts {
    public static func list(_ paths: AppPaths) throws -> [SteamAccount] {
        let users = try VDF.parse(FileStore.text(paths.steam.appendingPathComponent("config/loginusers.vdf"))).object("users")
        return (users?.entries ?? []).compactMap { entry in
            guard let info = entry.children, let name = info.string("AccountName") else { return nil }
            return SteamAccount(id: entry.key, name: name, persona: info.string("PersonaName") ?? name, recent: info.string("MostRecent") == "1")
        }
    }
    public static func select(_ account: SteamAccount, paths: AppPaths) throws {
        let usersURL = paths.steam.appendingPathComponent("config/loginusers.vdf")
        let registryURL = paths.steam.appendingPathComponent("registry.vdf")
        let data = try FileStore.read(usersURL); let registryData = try FileStore.read(registryURL)
        var root = try VDF.parse(String(decoding: data, as: UTF8.self))
        guard var users = root.object("users"), users.object(account.id) != nil else { throw AppFailure("本地账号凭证不存在 / Remembered local account credentials not found") }
        for i in users.entries.indices {
            let recent = users.entries[i].key == account.id ? "1" : "0"
            users.entries[i].children?.set("MostRecent", value: recent)
        }
        root.set("users", object: users)
        var registry = try VDF.parse(String(decoding: registryData, as: UTF8.self))
        var updated = false
        func change(_ value: inout VDF) {
            for i in value.entries.indices {
                if value.entries[i].key.caseInsensitiveCompare("AutoLoginUser") == .orderedSame { value.entries[i].value = account.name; updated = true }
                if var child = value.entries[i].children { change(&child); value.entries[i].children = child }
            }
        }
        change(&registry)
        guard updated else { throw AppFailure("registry.vdf 没有 AutoLoginUser；请先在 Steam 中启用记住登录 / No AutoLoginUser in registry.vdf; enable remembered sign-in in Steam first") }
        try FileTransaction(backupRoot: paths.backups).apply([(usersURL, Data(root.serialized().utf8)), (registryURL, Data(registry.serialized().utf8))], reason: "切换本地 Steam 账号", expectations: [usersURL: FileStore.hash(data), registryURL: FileStore.hash(registryData)])
    }
}

public struct SaveLocation: Identifiable, Sendable {
    public var id: String { url.path }
    public var appID: Int
    public var kind: String
    public var url: URL
    public init(appID: Int, kind: String, url: URL) { self.appID = appID; self.kind = kind; self.url = url }
}
public enum Saves {
    public static func locations(_ paths: AppPaths) -> [SaveLocation] {
        var result: [SaveLocation] = []
        for account in FileStore.files(paths.steam.appendingPathComponent("userdata")) {
            for app in FileStore.files(account) {
                guard let id = TextUtil.validID(app.lastPathComponent) else { continue }
                let remote = app.appendingPathComponent("remote")
                if FileStore.fm.fileExists(atPath: remote.path) { result.append(SaveLocation(appID: id, kind: "Steam remote", url: remote)) }
            }
        }
        for (id, prefix) in SteamLibrary.prefixes(paths) {
            for user in FileStore.files(prefix.appendingPathComponent("drive_c/users")) where user.lastPathComponent != "Public" {
                for suffix in ["Documents", "Saved Games", "AppData/Local", "AppData/LocalLow", "AppData/Roaming"] {
                    let url = user.appendingPathComponent(suffix)
                    if FileStore.fm.fileExists(atPath: url.path), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                        result.append(SaveLocation(appID: id, kind: "NotProton · \(suffix)", url: url))
                    }
                }
            }
        }
        return result.sorted { $0.appID < $1.appID }
    }
    public static func backup(_ sourceURL: URL, to destinationURL: URL) throws -> Int {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let destination = destinationURL.resolvingSymlinksInPath().standardizedFileURL
        guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw AppFailure("存档源必须是实际存在的目录 / Save source must be an existing directory") }
        guard !FileStore.fm.fileExists(atPath: destination.path), !destination.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") else { throw AppFailure("备份目标必须是新的独立目录 / Backup destination must be a new, separate directory") }
        for reserved in [".fluent-checksums.json", ".INCOMPLETE"] {
            guard !FileStore.fm.fileExists(atPath: source.appendingPathComponent(reserved).path) else { throw AppFailure("所选目录包含备份元数据；请选择实际的游戏存档目录 / Folder contains backup metadata; select the actual game save directory") }
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let iterator = FileStore.fm.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in enumerationError = error; return false }) else { throw AppFailure("无法读取存档目录 / Cannot read the save directory") }
        var snapshots: [(URL, String, Int, Date?)] = []; var size = 0
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { iterator.skipDescendants(); throw AppFailure("存档目录包含符号链接，请选择实际存档目录 / Save directory contains symbolic links; select the actual directory") }
            if values.isRegularFile == true {
                let actual = file.standardizedFileURL
                guard actual.path.hasPrefix(source.path + "/") else { throw AppFailure("存档枚举返回了目录外的文件 / A save file resolves outside the selected directory") }
                let relative = String(actual.path.dropFirst(source.path.count + 1)); size += values.fileSize ?? 0
                guard size <= 8 * 1024 * 1024 * 1024 else { throw AppFailure("此目录超过 8 GB，请选择更具体的存档子目录 / Directory exceeds 8 GB; select a smaller save subdirectory") }
                snapshots.append((file, relative, values.fileSize ?? 0, values.contentModificationDate))
            }
        }
        if let enumerationError { throw enumerationError }
        try FileStore.mkdir(destination)
        var checksums: [String: String] = [:]
        do {
            for (file, relative, size, date) in snapshots {
                let target = destination.appendingPathComponent(relative)
                try FileStore.mkdir(target.deletingLastPathComponent()); try FileStore.fm.copyItem(at: file, to: target)
                let now = try file.resourceValues(forKeys: keys)
                guard now.fileSize == size, now.contentModificationDate == date else { throw AppFailure("备份过程中存档发生变化，请退出游戏后重试 / Save changed during backup; close the game and retry") }
                let original = FileStore.hash(try FileStore.read(file)); let copied = FileStore.hash(try FileStore.read(target))
                guard original == copied else { throw AppFailure("备份校验失败 / Backup verification failed：\(relative)") }; checksums[relative] = original
            }
            try FileStore.json(checksums, to: destination.appendingPathComponent(".fluent-checksums.json"))
            return snapshots.count
        } catch {
            // Leave incomplete copies for inspection, explicitly marked; never delete the source.
            try? FileStore.write(Data(error.localizedDescription.utf8), to: destination.appendingPathComponent(".INCOMPLETE")); throw error
        }
    }
}
