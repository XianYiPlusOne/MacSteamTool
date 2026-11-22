import Foundation
import AppKit
import MacSteamToolCore
import Darwin

// Explicit maintenance CLI for the same installation API used by the app.
@main struct RuntimeCommand {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = Array(CommandLine.arguments.dropFirst()), paths = AppPaths()
            switch args.first {
            case "refresh-library":
                let target = args.count > 1 ? TextUtil.validID(args[1]) : nil
                let url = target.map { "steam://nav/games/details/\($0)" } ?? "steam://nav/games"
                print("Steam PIDs: \(SteamProcesses.pids())")
                print(await SteamLibraryRefresh.request(paths: paths, wake: { await MainActor.run { _ = NSWorkspace.shared.open(URL(string: url)!) } }))
            case "integration-status":
                guard (2...3).contains(args.count) else { throw AppFailure("integration-status APP_BUNDLE [READ_ONLY_FIXTURE]") }
                var inspectionPaths = paths
                if args.count == 3 {
                    let root = URL(fileURLWithPath: args[2]); inspectionPaths = AppPaths(home: root)
                    inspectionPaths.steamApp = root.appendingPathComponent("Steam.app")
                }
                print(try NativeIntegration.needsPreparation(paths: inspectionPaths, application: URL(fileURLWithPath: args[1])) ? "Preparation pending" : "Integration ready")
            case "validate-setup":
                try await SetupValidation.run(args)
            case "finish-setup-validation":
                guard args.count == 4 else { throw AppFailure("finish-setup-validation APP_BUNDLE GENERATED_FIXTURE FREE_DMG") }
                try await SetupValidation.finish(application: URL(fileURLWithPath: args[1]), fixture: URL(fileURLWithPath: args[2]).standardizedFileURL, archive: URL(fileURLWithPath: args[3]))
            case "status":
                print(FreeRuntime.installedRoot(paths)?.path ?? "Free runtime not installed")
            case "install":
                guard (2...4).contains(args.count) else { throw AppFailure("Usage: MacSteamToolRuntime install RESOURCES [PINNED_DMG [CLOUD_HELPER]]") }
                try await FreeRuntime.install(paths: paths, resources: URL(fileURLWithPath: args[1]), archive: args.count >= 3 ? URL(fileURLWithPath: args[2]) : nil, cloudHelper: args.count == 4 ? URL(fileURLWithPath: args[3]) : nil) { print($0) }
            case "select":
                guard args.count == 2, let id = TextUtil.validID(args[1]) else { throw AppFailure("Usage: MacSteamToolRuntime select APPID (Steam must be closed)") }
                let backup = try SteamCompatibility.save(paths: paths, appID: id, tool: FreeRuntime.toolID)
                print("Selected free runtime for \(id); backup: \(backup)")
            default:
                throw AppFailure("Usage: MacSteamToolRuntime status | install RESOURCES [PINNED_DMG] | select APPID")
            }
        } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
