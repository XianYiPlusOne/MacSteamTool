import Foundation
import MacSteamToolCore

enum GuideSteamInstallation: Equatable {
    case idle, downloading, installing, installed(URL), failed(String)

    var isRunning: Bool { self == .downloading || self == .installing }
    var installedApp: URL? {
        if case .installed(let url) = self { return url }
        return nil
    }
}

extension AppModel {
    var guideSteamDestination: URL {
        if testing { return home.appendingPathComponent("Applications/Steam.app") }
        return OneClickSetup.resolveSteamPath(paths).steamApp
    }

    func installSteamFromGuide() async {
        guard !busy, !guideSteamInstallation.isRunning, !runtimePreparation.working else { return }
        let target = guideSteamDestination
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacSteamTool-Steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                guideSteamInstallation = .downloading
                let prepared = try await NativeSteamBootstrap.prepare(cache: temporary)
                guideSteamInstallation = .installing
                try await NativeSteamBootstrap.install(prepared, at: target)
            }
        } catch {
            // A second app instance may have finished installing the same signed client.
            guard NativeSteamBootstrap.isSteamApplication(target) else {
                guideSteamInstallation = .failed(error.localizedDescription)
                return
            }
        }
        guard NativeSteamBootstrap.isSteamApplication(target) else {
            let message = tr("安装位置已有其他文件，无法识别为 Steam。请检查该位置。", "The install location contains an item that could not be identified as Steam. Check this location.")
            guideSteamInstallation = .failed(message + "\n" + target.path)
            return
        }
        runtimePreparation.reset()
        guideSteamInstallation = .installed(target)
    }
}
