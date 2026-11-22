import Foundation
import Darwin

@main struct InstallerMain {
    static func write(_ value: [String: Any], to path: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: URL(filePath: path), options: .atomic)
    }
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args.count == 3, args[0] == "--test-owned-backend" { try InstallerSelfTest.ownedBackend(application: args[1], crossOver: args[2]); return }
            if args.count == 2, args[0] == "--test-core" { try InstallerSelfTest.coreIntegration(application: args[1]); return }
            if args.count == 5, args[0] == "--test-managed" {
                let root = try await InstallerSelfTest.managedIntegration(steam: args[1], mac: args[2], np: args[3], repair: args[4])
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["fixture": root]), as: UTF8.self)); return
            }
            if args.first == "--rebuild-prefix" {
                _ = setsid()
                try RebuildPrefixCommand.run(Array(args.dropFirst()))
                return
            }
            if args.count == 2, args[0] == "--test-kernel" { try InstallerSelfTest.kernelIntegration(companion: args[1]); return }
            if args == ["--self-test"] { try InstallerSelfTest.run(); return }
            if args == ["--test-architectures"] { try InstallerSelfTest.architectures(); return }
            if args.count == 2, args[0] == "--test-notproton-repair" { try InstallerSelfTest.notProtonRepair(source: args[1]); return }
            if args.count == 2, args[0] == "--inspect" {
                try InstallSession.companion(args[1])
                let payload = try InstallPayload.locate(); let bridge = try BridgePayload.locate()
                let report: [String: Any] = ["ok": true, "version": AppVersion.bundled, "builtAt": payload.builtAt, "signatures": payload.signatures.count, "bridgeSources": bridge.sources.count, "runners": RunnerStore.installedBuilds().map(\.id), "steamRunning": SteamBundle.isRunning]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)); return
            }
            guard args.count == 3, ["--install", "--restore", "--kernel", "--restore-kernel"].contains(args[0]) else { throw StepFailure(step: "Arguments", detail: "Usage: --inspect companion.app or --install request.json response.json") }
            let r = try JSONDecoder().decode(InstallRequest.self, from: Data(contentsOf: URL(filePath: args[1])))
            let output = args[2]
            let backup: String
            if args[0] == "--restore" { backup = try InstallSession.restore(r) }
            else if args[0] == "--restore-kernel" { backup = try InstallSession.restoreKernel(r) }
            else if args[0] == "--kernel" { backup = try InstallSession.kernel(r) { message in try? write(["progress": message], to: output + ".status") } }
            else { backup = try await InstallSession.install(r) { message in try? write(["progress": message], to: output + ".status") } }
            try write(["ok": true, "backup": backup], to: output)
        } catch {
            if args.count == 3, ["--install", "--restore", "--kernel", "--restore-kernel"].contains(args[0]) { try? write(["ok": false, "error": error.localizedDescription], to: args[2]) }
            else { let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription]); print(String(decoding: data ?? Data(), as: UTF8.self)) }
            exit(1)
        }
    }
}
