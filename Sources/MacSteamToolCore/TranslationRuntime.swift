import Foundation

/// Optional backends for the internally managed macSteam / NotProton cores.
/// Installing a backend never selects it globally or rewrites a game's choice.
public enum TranslationRuntime {
    public static func requireCores(_ paths: AppPaths) throws {
        guard RuntimeStatus.read(paths).bothInjected else {
            throw AppFailure("游戏环境仍在自动准备，请稍后重试 / The gaming environment is still being prepared; retry shortly")
        }
    }
    /// Reuse the runner belonging to this CrossOver build, including externally
    /// managed installs; never silently select another installed CrossOver version.
    public static func registeredCrossOverTool(paths: AppPaths, source: URL) throws -> String? {
        guard let bytes = try? FileStore.read(source.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let build = info["CFBundleVersion"] as? String,
              build.range(of: #"^\d+(?:\.\d+){1,4}$"#, options: .regularExpression) != nil else { return nil }
        let available = Set(try SteamCompatibility.tools(paths: paths).map(\.id))
        let rows = ((try? FileStore.text(paths.notProton.appendingPathComponent("tools"))) ?? "").split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        return rows.filter { row in
            guard row.count >= 3, available.contains(row[0]), row[0] == "notproton" || row[0].hasPrefix("notproton-"),
                  row[1] == build || row[1] == build + "-fex", row[2] == "rosetta" || row[2] == "fex" else { return false }
            return FileStore.fm.isExecutableFile(atPath: paths.notProton.appendingPathComponent("runners/crossover-\(row[1])/CrossOver/bin/wine").path)
        }.sorted { ($0[2] == "rosetta" ? 0 : 1, $0[0]) < ($1[2] == "rosetta" ? 0 : 1, $1[0]) }.first?.first
    }
    public static func installCrossOver(paths: AppPaths, crossOver: URL, application: URL,
                                       progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws {
        try requireCores(paths)
        guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
        guard FileStore.fm.isExecutableFile(atPath: crossOver.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").path) else {
            throw AppFailure("请选择用户已购买并激活的 CrossOver.app / Choose your purchased and activated CrossOver.app")
        }
        let version = RuntimeStatus.read(paths).notProtonVersion
        guard version == ManagedRuntimeComponents.versions["notproton"] else {
            throw AppFailure("此 CrossOver 适配器需要 NotProton 1.2.3；已保留当前内核和运行器 / This adapter requires NotProton 1.2.3; current cores and runners were preserved")
        }
        guard await OneClickSetup.rosettaAvailable() else { throw AppFailure("请先安装 Rosetta 2 / Install Rosetta 2 first") }
        await progress("准备 CrossOver 桥接组件 / Preparing CrossOver integration components…")
        // These bridges and launchers are compiled by MacSteamTool from maintained
        // sources. Runtime preparation never downloads an upstream manager.
        let component = try ManagedRuntimeComponents.prepareCrossOver(paths: paths, application: application)
        _ = try await RuntimeInstaller.run(paths: paths, crossOver: crossOver, managedRoot: component.root,
            managedVersion: component.version, application: application, status: progress)
        _ = try await RuntimeInstaller.run(paths: paths, kernel: "notproton.dylib", application: application, status: progress)
        guard !(try SteamCompatibility.tools(paths: paths)).filter({ $0.id == "notproton" || $0.id.hasPrefix("notproton-") }).isEmpty else {
            throw AppFailure("CrossOver 运行器未注册，请查看安装备份 / CrossOver runner not registered; review installation backups")
        }
        await progress("CrossOver 已添加，可在各游戏的兼容性设置中选择 / CrossOver added; select it in each game's compatibility settings")
    }
}
