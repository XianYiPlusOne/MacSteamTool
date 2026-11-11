import Foundation

public enum WindowsArchitecture: String, Codable, Sendable { case x86, x64 }
public struct WindowsBinary: Sendable {
    public let architecture: WindowsArchitecture
    public let isDLL: Bool
    public static func inspect(_ data: Data) throws -> Self {
        let magic = Array(data.prefix(4))
        if [[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca], [0xfe,0xed,0xfa,0xce]].contains(magic) {
            throw AppFailure("不支持原生 macOS 游戏或 Mach-O 补丁；仅支持 NotProton / CrossOver 中的 Windows 游戏 / Native macOS games and Mach-O patches are unsupported")
        }
        guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a else { throw AppFailure("不是 Windows PE 程序 / Not a Windows PE binary") }
        func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i+1]) << 8 }
        let offset = (0..<4).reduce(0) { $0 | Int(data[60+$1]) << ($1*8) }
        guard offset >= 64, offset <= min(16*1024*1024, data.count-24), data[offset..<(offset+4)] == Data([0x50,0x45,0,0]) else { throw AppFailure("Windows PE 头损坏或截断 / Invalid or truncated PE header") }
        let arch: WindowsArchitecture
        switch u16(offset+4) { case 0x14c: arch = .x86; case 0x8664: arch = .x64; default: throw AppFailure("仅支持 Windows x86 / x64；不支持 ARM 或其他架构 / Only Windows x86/x64 are supported") }
        let sections = u16(offset+6), optional = u16(offset+20), flags = u16(offset+22), minimum = arch == .x64 ? 112 : 96
        guard flags & 2 != 0, (1...96).contains(sections), optional >= minimum,
              offset+24+optional+sections*40 <= data.count,
              u16(offset+24) == (arch == .x64 ? 0x20b : 0x10b) else { throw AppFailure("PE 架构、可选头或段表不一致 / Inconsistent PE architecture, optional header or sections") }
        return Self(architecture: arch, isDLL: flags & 0x2000 != 0)
    }
}

public struct PatchWindowsTarget: Codable, Sendable, Equatable {
    public enum RuntimeKind: String, Codable, Sendable { case notProton, crossOver }
    public let kind: RuntimeKind
    public let executable: String
    public let executableHash: String
    public let architecture: WindowsArchitecture
    public let prefix: String
    public let loader: String
    public let server: String
    public let crossOverApp: String?

    public static func inspect(executable: URL, gameRoot: URL, appID: Int, paths: AppPaths, bottle: URL? = nil, crossOverApp: URL? = nil) throws -> Self {
        guard executable.pathExtension.lowercased() != "app" else { throw AppFailure("不支持原生 macOS 游戏；请选择 Windows 游戏 .exe / Native macOS games are unsupported; select a Windows game .exe") }
        _ = try GamePatches.target(executable.standardizedFileURL.pathComponents.dropFirst(gameRoot.standardizedFileURL.pathComponents.count).joined(separator: "/"), root: gameRoot)
        let file = executable.resolvingSymlinksInPath().standardizedFileURL
        let bytes = try FileStore.read(file), binary = try WindowsBinary.inspect(bytes)
        _ = try WineOverrides.executable(executable, inside: gameRoot)
        guard !binary.isDLL else { throw AppFailure("目标必须是 Windows 游戏程序，不能是 DLL / Target must be a Windows game executable") }
        let launch: WineLaunch
        if let bottle, let crossOverApp { launch = try WineLaunch.crossOver(bottle: bottle, application: crossOverApp, command: file.path, appID: appID) }
        else { guard bottle == nil, crossOverApp == nil else { throw AppFailure("请选择完整的 CrossOver 应用与容器 / Select both CrossOver and its bottle") }; launch = try WineLaunch.prepare(appID: appID, command: file.path, paths: paths) }
        try validatePrefix(launch.prefix)
        return Self(kind: bottle == nil ? .notProton : .crossOver, executable: file.path, executableHash: FileStore.hash(bytes), architecture: binary.architecture,
                    prefix: launch.prefix.resolvingSymlinksInPath().path, loader: launch.executable.resolvingSymlinksInPath().path,
                    server: URL(fileURLWithPath: launch.environment["WINESERVER"]!).resolvingSymlinksInPath().path, crossOverApp: crossOverApp?.resolvingSymlinksInPath().path)
    }
    static func validatePrefix(_ prefix: URL) throws {
        for name in ["user.reg", "system.reg"] {
            let file = prefix.appendingPathComponent(name)
            guard let registry = try? FileStore.text(file), registry.hasPrefix("WINE REGISTRY Version 2") else { throw AppFailure("Windows 容器尚未初始化或注册表无效 / Windows bottle is not initialized or registry is invalid") }
            guard !registry.contains("#arch=win32") else { throw AppFailure("加载检查要求 64 位 Windows 容器（可运行 x86 游戏）；不支持纯 32 位容器 / Module checks require a 64-bit Windows bottle, which can run x86 games") }
        }
        var directory: ObjCBool = false
        guard FileStore.fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path, isDirectory: &directory), directory.boolValue else { throw AppFailure("Windows 容器缺少 drive_c / Bottle has no drive_c") }
    }
    public func launch(appID: Int, command: String, paths: AppPaths) throws -> WineLaunch {
        let value: WineLaunch
        if kind == .crossOver, let crossOverApp {
            value = try WineLaunch.crossOver(bottle: URL(fileURLWithPath: prefix), application: URL(fileURLWithPath: crossOverApp), command: command, appID: appID)
        } else { value = try WineLaunch.prepare(appID: appID, command: command, paths: paths) }
        guard value.prefix.resolvingSymlinksInPath().path == prefix, value.executable.resolvingSymlinksInPath().path == loader,
              value.environment["WINESERVER"].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == server else { throw AppFailure("游戏容器或运行器已改变，请重新预览 / Game bottle or runner changed; preview again") }
        try Self.validatePrefix(value.prefix); return value
    }
    public func validateFiles(_ entries: [PatchEntry]) throws {
        for entry in entries {
            let ext = URL(fileURLWithPath: entry.relative).pathExtension.lowercased()
            if ext == "sys" { throw AppFailure("不支持 Windows 内核驱动补丁 / Windows kernel-driver patches are unsupported") }
            let magic = Array(entry.data.prefix(4))
            let binary = ["dll", "exe", "dylib"].contains(ext) || entry.data.starts(with: [0x4d,0x5a]) || [[0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca], [0xfe,0xed,0xfa,0xce]].contains(magic)
            guard binary else { continue }
            let info = try WindowsBinary.inspect(entry.data)
            guard info.architecture == architecture else { throw AppFailure("补丁与游戏架构不一致 / Patch/game architecture mismatch: \(entry.relative) (\(info.architecture.rawValue) / \(architecture.rawValue))") }
            guard (ext != "dll" || info.isDLL) && (ext != "exe" || !info.isDLL) else { throw AppFailure("补丁文件类型与 PE 标志不一致 / Patch file type does not match PE flags: \(entry.relative)") }
        }
    }
}
