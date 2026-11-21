import Foundation
import Darwin

public enum GraphicsRenderer: String, CaseIterable, Sendable {
    case automatic = "auto", dxmt, dxvk, wined3d, d3dmetal
    public var name: String {
        switch self {
        case .automatic: return "Automatic"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        case .d3dmetal: return "D3DMetal"
        }
    }
}

/// CrossOver resolves CX_GRAPHICS_BACKEND internally. Standalone Wine selects
/// a renderer overlay before the loader starts, including for direct EXE launches.
private protocol GraphicsDriver: Sendable {
    var renderers: [GraphicsRenderer] { get }
    func configure(_ selected: GraphicsRenderer, runner: URL, environment: inout [String: String]) throws
}

private struct CrossOverGraphicsDriver: GraphicsDriver {
    let fex: Bool
    var renderers: [GraphicsRenderer] { GraphicsRenderer.allCases.filter { !fex || $0 != .d3dmetal } }
    func configure(_ selected: GraphicsRenderer, runner: URL, environment: inout [String: String]) throws {
        environment["CX_GRAPHICS_BACKEND"] = selected != .automatic && renderers.contains(selected) ? selected.rawValue : nil
    }
}

private struct WineGraphicsDriver: GraphicsDriver {
    let renderers = GraphicsRenderer.allCases
    func configure(_ selected: GraphicsRenderer, runner: URL, environment: inout [String: String]) throws {
        // A helper may run before Steam has classified this game's executable.
        let metal4 = environment["CX_GRAPHICS_BACKEND"] == "d3dmetal4" && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 &&
            FileStore.fm.fileExists(atPath: runner.appendingPathComponent("lib/external/d3dmetal4/libd3dshared.dylib").path)
        let renderer: GraphicsRenderer = environment["CX_GRAPHICS_BACKEND"] == "d3dmetal4" ? .d3dmetal : (selected == .automatic ? .dxmt : selected)
        let directory = metal4 ? "d3dmetal4" : renderer.rawValue
        environment["CX_ACTIVE_GRAPHICS_BACKEND"] = renderer.rawValue
        environment["WINEDLLPATH_PREPEND"] = nil
        environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = nil
        guard renderer != .wined3d else { return }
        let overlay = runner.appendingPathComponent("lib/renderers/\(directory)")
        guard FileStore.fm.fileExists(atPath: overlay.appendingPathComponent("x86_64-windows/d3d11.dll").path) else {
            throw AppFailure("\(renderer.name) 组件缺失，请在运行环境中更新 Wine / Update Wine to install \(renderer.name)")
        }
        environment["WINEDLLPATH_PREPEND"] = overlay.path
        if renderer == .d3dmetal {
            let library = runner.appendingPathComponent(metal4 ? "lib/external/d3dmetal4/libd3dshared.dylib" : "lib/external/libd3dshared.dylib")
            if metal4 { environment["D3DM_MTL4"] = "0" }
            guard FileStore.fm.fileExists(atPath: library.path) else { throw AppFailure("D3DMetal 组件不完整 / Incomplete D3DMetal runtime") }
            environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = library.path
        }
    }
}

/// One definition drives the editor, accepted values and the launch environment.
public struct CompatibilityOption: Identifiable, Sendable {
    public let id: String
    public let chinese: String
    public let english: String
    public let choices: [String]?
    let defaultValue: String
    let clause: String?
    let enableKey: String?

    init(_ key: String, _ zh: String, _ en: String, choices: [String]? = nil,
         initial: String = "0", clause: String? = nil, enableKey: String? = nil) {
        id = key; chinese = zh; english = en; self.choices = choices
        defaultValue = initial; self.clause = clause; self.enableKey = enableKey
    }
    var key: String { clause == nil ? id : "DXMT_CONFIG" }
    func clauses(_ values: [String: String]) -> [String] {
        (values[key] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    public func value(in settings: [String: String]) -> String {
        if let enableKey, settings[enableKey] != "1" { return defaultValue }
        guard let clause else { return settings[key] ?? defaultValue }
        return clauses(settings).first { $0.hasPrefix(clause + "=") }.map { String($0.dropFirst(clause.count + 1)) } ?? defaultValue
    }
    func apply(_ value: String, to settings: inout [String: String]) {
        if let clause {
            var rest = clauses(settings).filter { !$0.hasPrefix(clause + "=") }
            if !value.isEmpty { rest.append(clause + "=" + value) }
            settings[key] = rest.isEmpty ? nil : rest.joined(separator: ";")
        } else {
            settings[key] = value == "auto" ? nil : value
        }
        if let enableKey { settings[enableKey] = value.isEmpty ? nil : "1" }
    }
}

/// The same defaults are read by Steam's Compatibility page and both launchers.
/// CrossOver can override its architecture defaults for a particular build.
public struct RunnerCompatibility: Sendable {
    private let driver: any GraphicsDriver
    private let family: URL
    private let buildDefaults: URL?
    private let isWine: Bool
    private let fex: Bool
    public var renderers: [GraphicsRenderer] { driver.renderers }

    public init(backend: ContainerBackend, paths: AppPaths) {
        self.init(wine: backend.isWine, build: backend.build, fex: backend.flavor == "fex", paths: paths)
    }
    init(wine: Bool, build: String?, fex: Bool, paths: AppPaths) {
        self.fex = fex
        isWine = wine
        driver = wine ? WineGraphicsDriver() as any GraphicsDriver : CrossOverGraphicsDriver(fex: fex)
        let flavor = fex ? "fex" : "rosetta"
        family = paths.notProton.appendingPathComponent("defaults-\(flavor)")
        if !wine, let build, build.range(of: #"^\d+(?:\.\d+){1,4}(?:-fex)?$"#, options: .regularExpression) != nil {
            buildDefaults = paths.notProton.appendingPathComponent("defaults-override-\(build)-\(flavor)")
        } else { buildDefaults = nil }
    }
    public func settings() throws -> [String: String] {
        let file = buildDefaults.flatMap { FileStore.fm.fileExists(atPath: $0.path) ? $0 : nil } ?? family
        return try read(file)
    }
    private func read(_ file: URL) throws -> [String: String] {
        guard FileStore.fm.fileExists(atPath: file.path) else { return [:] }
        var values: [String: String] = [:]
        for line in try FileStore.text(file).components(separatedBy: .newlines) {
            guard let split = line.firstIndex(of: "=") else { continue }
            values[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        return values
    }

    public func options(for renderer: GraphicsRenderer) -> [CompatibilityOption] {
        var options = [
            CompatibilityOption("CX_GRAPHICS_BACKEND", "图形后端", "Graphics backend",
                                choices: renderers.map(\.rawValue), initial: "auto"),
            CompatibilityOption("NOTPROTON_RETINA", "高分辨率模式", "High Resolution"),
            CompatibilityOption("WINEMSYNC", "MSync 同步", "MSync", initial: isWine ? "1" : "0"),
            CompatibilityOption("MTL_HUD_ENABLED", "Metal 性能监视器", "Metal performance HUD")
        ]
        if renderer == .dxmt || renderer == .automatic {
            options += [
                CompatibilityOption("DXMT_ENABLE_NVEXT", "DLSS（DXMT）", "DLSS (DXMT)"),
                CompatibilityOption("dxmt-scale", "MetalFX 空间放大倍率", "MetalFX spatial upscaling",
                                    choices: ["", "1.5", "1.72", "2.0", "3.0"], initial: "",
                                    clause: "d3d11.metalSpatialUpscaleFactor", enableKey: "DXMT_METALFX_SPATIAL_SWAPCHAIN"),
                CompatibilityOption("dxmt-fps", "DXMT 帧率上限", "DXMT frame rate limit",
                                    choices: ["", "30", "40", "60", "120", "144"], initial: "", clause: "d3d11.preferredMaxFrameRate")
            ]
        }
        if !fex && (renderer == .d3dmetal || renderer == .automatic) {
            options.append(CompatibilityOption("D3DM_ENABLE_METALFX", "DLSS（D3DMetal）", "DLSS (D3DMetal)"))
        }
        options.append(fex ? CompatibilityOption("FEX_X87REDUCEDPRECISION", "降低 x87 精度", "Reduced x87 precision", initial: "1")
                           : CompatibilityOption("ROSETTA_ADVERTISE_AVX", "向游戏报告 AVX2 支持", "Advertise AVX2 to games", initial: "1"))
        options += [
            CompatibilityOption("NOTPROTON_RAW_CONTROLLERS", "让游戏直接读取控制器", "Let games read controllers directly"),
            CompatibilityOption("NOTPROTON_DISABLE_HIDRAW", "停用 hidraw", "Disable hidraw")
        ]
        return options
    }

    public func set(_ value: String, for option: CompatibilityOption,
                    requireIdle: () throws -> Void = GameContainers.requireIdle) throws {
        try requireIdle()
        let folder = family.deletingLastPathComponent()
        try FileStore.mkdir(folder)
        let fd = open(folder.appendingPathComponent(".fluent-compatibility.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try requireIdle()
        var values = try settings()
        let renderer = values["CX_GRAPHICS_BACKEND"].flatMap(GraphicsRenderer.init(rawValue:)) ?? .automatic
        guard let current = options(for: renderer).first(where: { $0.id == option.id }),
              (current.choices ?? ["0", "1"]).contains(value) else {
            throw AppFailure("当前运行器或图形后端不支持此设置 / Setting unavailable for the current backend")
        }
        current.apply(value, to: &values)
        let text = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
        guard text.utf8.count <= 1024 else { throw AppFailure("兼容性设置超过运行器的读取上限 / Compatibility defaults exceed the runner file limit") }
        try FileStore.write(Data(text.utf8), to: buildDefaults ?? family)
    }

    func configureTool(runner: URL, prefix: URL, environment: inout [String: String]) throws {
        let root = prefix.deletingLastPathComponent()
        let session = try read(root.appendingPathComponent("notproton-session.env"))
        let saved = try settings().merging(session) { _, perGame in perGame }
        for option in options(for: .automatic) {
            if let value = saved[option.key] { environment[option.key] = value }
            if let key = option.enableKey, let value = saved[key] { environment[key] = value }
        }
        let sync = try? FileStore.text(root.appendingPathComponent("notproton-msync")).trimmingCharacters(in: .whitespacesAndNewlines)
        if let sync, ["0", "1"].contains(sync) { environment["WINEMSYNC"] = sync }
        if environment["WINEMSYNC"] == nil { environment["WINEMSYNC"] = isWine ? "1" : "0" }
        let selected = environment["CX_GRAPHICS_BACKEND"].flatMap(GraphicsRenderer.init(rawValue:)) ?? .automatic
        try driver.configure(selected, runner: runner, environment: &environment)
    }
}
