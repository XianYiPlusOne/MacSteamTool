import Foundation

public struct ManagedRuntimeComponent: Codable, Sendable {
    public let provider: String
    public let version: String
    public let source: String
    public let files: [String: String]
    public var root: URL
    public init(provider: String, version: String, source: String, files: [String: String], root: URL) {
        self.provider = provider; self.version = version; self.source = source; self.files = files; self.root = root
    }
    public var resources: URL { root.appendingPathComponent(provider == "macsteam" ? "Resources" : "NotProtonRuntime.bundle/Contents/Resources") }
}

public enum ManagedRuntimeComponents {
    /// The initial one-click track uses the versions exercised with our adapter.
    public static let versions = ["macsteam": "0.8.2", "notproton": "1.2.3"]
    public static func prepare(provider: String, paths: AppPaths, engine: URL, localApplication: URL? = nil, application: URL? = nil) async throws -> ManagedRuntimeComponent {
        guard let version = versions[provider] else { throw AppFailure("未知组件 / Unknown component") }
        let folder = paths.data.appendingPathComponent("Components/\(provider)/\(version)")
        if let application, localApplication == nil {
            return try prepareBundled(provider: provider, paths: paths, application: application)
        }
        // Legacy import is explicit. Never discover or download either manager
        // when an internal component is missing.
        guard let localApplication else {
            throw AppFailure("应用内组件缺失，请安装完整版本 / Internal components missing; install the complete MacSteamTool app")
        }
        let application = localApplication
        let source = "Explicit legacy import: \(localApplication.lastPathComponent)"
        // Local sources receive the same app identity, signature, architecture,
        // required-resource and link checks. No manager executable is launched.
        _ = try await OfficialRuntimeUpdates.validateApplication(application, provider: provider, version: version)
        let stage = folder.deletingLastPathComponent().appendingPathComponent("stage-\(UUID().uuidString)")
        try FileStore.mkdir(stage); defer { try? FileStore.fm.removeItem(at: stage) }
        if provider == "macsteam" {
            let from = application.appendingPathComponent("Contents/Resources"), to = stage.appendingPathComponent("Resources")
            try FileStore.mkdir(to)
            for name in ["macsteam.dylib", "macsteam.dylib.version", "signatures"] { try FileStore.fm.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name)) }
        } else {
            try FileStore.fm.copyItem(at: application.appendingPathComponent("Contents/Resources/NotProtonApp_NotProtonApp.bundle"), to: stage.appendingPathComponent("NotProtonRuntime.bundle"))
        }
        let files = try inventory(stage)
        let result = ManagedRuntimeComponent(provider: provider, version: version, source: source, files: files, root: folder)
        try FileStore.json(result, to: stage.appendingPathComponent("component.json"))
        // Never delete a resource version used by an installed runtime. Retain a
        // replaced/corrupt cache beside it for diagnosis; installation checks hashes.
        let prior = folder.deletingLastPathComponent().appendingPathComponent("previous-\(UUID().uuidString)")
        let existed = FileStore.fm.fileExists(atPath: folder.path)
        if existed { try FileStore.fm.moveItem(at: folder, to: prior) }
        do { try FileStore.fm.moveItem(at: stage, to: folder) }
        catch { if existed { try FileStore.fm.moveItem(at: prior, to: folder) }; throw error }
        try validate(result); return result
    }
    /// MacSteamTool's own source-built components. Explicit legacy imports above are
    /// retained for compatibility; there is no automatic upstream app fallback.
    public static func prepareBundled(provider: String, paths: AppPaths, application: URL) throws -> ManagedRuntimeComponent {
        guard let version = versions[provider] else { throw AppFailure("Unknown component") }
        let embedded = application.appendingPathComponent("Contents/Resources/RuntimeComponents/\(provider)/\(version)")
        return try prepareEmbedded(provider: provider, version: version, paths: paths, embedded: embedded, cacheName: "bundled-" + version)
    }
    public static func prepareCrossOver(paths: AppPaths, application: URL) throws -> ManagedRuntimeComponent {
        let version = versions["notproton"]!
        return try prepareEmbedded(provider: "notproton", version: version, paths: paths,
            embedded: application.appendingPathComponent("Contents/Resources/RuntimeBackends/crossover"), cacheName: "crossover-" + version)
    }
    private static func prepareEmbedded(provider: String, version: String, paths: AppPaths, embedded: URL, cacheName: String) throws -> ManagedRuntimeComponent {
        guard var component = try? FileStore.decode(ManagedRuntimeComponent.self, at: embedded.appendingPathComponent("component.json")), component.provider == provider, component.version == version else {
            throw AppFailure("应用内缺少 \(provider) 组件，请安装完整版本 / Bundled component missing; install the complete app")
        }
        component.root = embedded; try validate(component)
        let target = paths.data.appendingPathComponent("Components/\(provider)/\(cacheName)")
        if let existing = try? FileStore.decode(ManagedRuntimeComponent.self, at: target.appendingPathComponent("component.json")),
           existing.provider == provider, existing.version == version, existing.root.standardizedFileURL.path == target.standardizedFileURL.path, existing.files == component.files, (try? validate(existing)) != nil { return existing }
        let stage = target.deletingLastPathComponent().appendingPathComponent("stage-\(UUID().uuidString)")
        try FileStore.mkdir(stage.deletingLastPathComponent())
        try FileStore.fm.copyItem(at: embedded, to: stage)
        defer { try? FileStore.fm.removeItem(at: stage) }
        component.root = target
        try FileStore.json(component, to: stage.appendingPathComponent("component.json"))
        let prior = target.deletingLastPathComponent().appendingPathComponent("previous-\(UUID().uuidString)")
        let exists = FileStore.fm.fileExists(atPath: target.path)
        if exists { try FileStore.fm.moveItem(at: target, to: prior) }
        do { try FileStore.fm.moveItem(at: stage, to: target) }
        catch { if exists { try FileStore.fm.moveItem(at: prior, to: target) }; throw error }
        try validate(component); return component
    }
    public static func inventory(_ root: URL) throws -> [String: String] {
        guard let walk = FileStore.fm.enumerator(atPath: root.path) else { throw AppFailure("组件目录不存在 / Component folder missing") }
        var files: [String: String] = [:]
        // DirectoryEnumerator's URL form can expand /var to /private/var.
        // Use its relative names so moving a stage cannot change receipt keys.
        for case let relative as String in walk {
            let url = root.appendingPathComponent(relative)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw AppFailure("组件资源不允许符号链接 / Component resources must not contain symlinks") }
            if info.isRegularFile == true, relative != "component.json" {
                files[relative] = FileStore.hash(try FileStore.read(url))
            }
        }
        return files
    }
    public static func validate(_ component: ManagedRuntimeComponent) throws {
        let actual = try inventory(component.root)
        let changed = Set(actual.keys).union(component.files.keys).filter { actual[$0] != component.files[$0] }.sorted()
        guard !component.files.isEmpty, changed.isEmpty else { throw AppFailure("\(component.provider) 组件校验失败，请重新安装完整应用 / Component integrity failed: \(changed.prefix(4).joined(separator: ", "))") }
    }
}
