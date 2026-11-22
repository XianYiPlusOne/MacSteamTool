import Foundation

/// Read-only health check for the automatically managed native Steam integration.
/// It ignores user game/configuration contents and never selects a backend.
public enum NativeIntegration {
    public static func needsPreparation(paths: AppPaths, application: URL) throws -> Bool {
        let p = OneClickSetup.resolveSteamPath(paths), fm = FileStore.fm
        guard !RuntimeInstaller.backups(p).contains(where: \.interrupted) else { throw AppFailure("上次准备被中断，请先在诊断与恢复中恢复记录 / Previous preparation was interrupted; recover it in Diagnostics and recovery first") }
        guard fm.fileExists(atPath: p.steamApp.path) else { return true }
        let info = try PropertyListSerialization.propertyList(from: FileStore.read(p.steamApp.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "com.valvesoftware.steam" else { throw AppFailure("所选应用不是原生 Steam / Selected application is not native Steam") }
        let env = info?["LSEnvironment"] as? [String: String] ?? [:]
        let inserts = Set((env["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init))
        func matches(_ source: URL, _ destination: URL) throws -> Bool {
            let expected = try FileStore.read(source)
            return (try? FileStore.read(destination)) == expected
        }
        var needsWork = !fm.fileExists(atPath: p.config.path)
        var macSteamResources: URL?
        for provider in ["macsteam", "notproton"] {
            let version = ManagedRuntimeComponents.versions[provider]!
            let support = provider == "macsteam" ? p.macSteam : p.notProton
            let installed = (try? FileStore.text(support.appendingPathComponent("dylib.version")))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let library = p.steamApp.appendingPathComponent("Contents/MacOS/\(provider).dylib")
            let present = inserts.contains(library.path) && fm.fileExists(atPath: library.path)
            if OneClickSetup.preserveNewer(installed: installed, candidate: version) {
                guard present else { throw AppFailure("现有组件版本较新且接入不完整，请更新 MacSteamTool 后重试 / A newer component has an incomplete integration; update MacSteamTool and retry") }
                continue
            }
            let root = application.appendingPathComponent("Contents/Resources/RuntimeComponents/\(provider)/\(version)")
            var component = try FileStore.decode(ManagedRuntimeComponent.self, at: root.appendingPathComponent("component.json"))
            component.root = root
            guard component.provider == provider, component.version == version else { throw AppFailure("应用组件版本不一致，请重新安装 MacSteamTool / Bundled component identity mismatch; reinstall MacSteamTool") }
            try ManagedRuntimeComponents.validate(component)
            if provider == "macsteam" { macSteamResources = component.resources }
            let source = provider == "macsteam" ? component.resources.appendingPathComponent("macsteam.dylib") : application.appendingPathComponent("Contents/Resources/Helpers/NotProtonRepair/notproton.dylib")
            if try !present || installed != version || !matches(source, library) { needsWork = true }
            let resourcePrefix = provider == "macsteam" ? "Resources/" : "NotProtonRuntime.bundle/Contents/Resources/payload/"
            for relative in component.files.keys where relative.hasPrefix(resourcePrefix) {
                let name = String(relative.dropFirst(resourcePrefix.count))
                let destination: URL
                if name.hasPrefix("signatures/") { destination = support.appendingPathComponent(name) }
                else if provider == "notproton", ["overlay-shim.dylib", "iconmaker", "appinfo"].contains(name) { destination = support.appendingPathComponent(name) }
                else { continue }
                if !(try matches(root.appendingPathComponent(relative), destination)) { needsWork = true }
            }
            if provider == "notproton" {
                let helper = application.appendingPathComponent("Contents/Helpers/NotProton/MacSteamToolNotProton").path
                if (try? FileStore.text(support.appendingPathComponent("app-executable"))) != helper { needsWork = true }
            }
        }
        for (name, folder, file) in KernelDeployment.bundledExtensions {
            let library = p.steamApp.appendingPathComponent("Contents/MacOS/\(name)")
            if try !inserts.contains(library.path) || !matches(application.appendingPathComponent("Contents/Helpers/\(folder)/\(file)"), library) { needsWork = true }
        }
        let expected = ["SDL_JOYSTICK_BLACKLIST_DEVICES": "0x05ac/0x0004", "FLUENT_CLOUD_ROOT": p.data.path, "FLUENT_CLOUD_STEAM": p.steam.path,
                        "FLUENT_PINS_CONFIG": p.config.path, "FLUENT_PINS_CACHE": p.steam.appendingPathComponent("depotcache").path,
                        "FLUENT_PINS_STATUS": p.data.appendingPathComponent("manifest-pins.log").path]
        if expected.contains(where: { env[$0.key] != $0.value }) { needsWork = true }
        if needsWork, let macSteamResources {
            try OneClickSetup.checkProfileAvailability(paths: p, resources: macSteamResources)
        }
        return needsWork
    }
}
