import Foundation
import MacSteamToolCore

@main struct Updater {
    static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let file = URL(fileURLWithPath: CommandLine.arguments[1]), status = file.deletingLastPathComponent().appendingPathComponent("install-result.json")
        do {
            let plan = try FileStore.decode(UpdateInstallPlan.self, at: file)
            let backup = try await AppUpdates.install(plan)
            try FileStore.json(["ok": "true", "backup": backup.path], to: status)
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/open"), [plan.target.path])
        } catch {
            try? FileStore.json(["ok": "false", "error": error.localizedDescription], to: status)
            fputs(error.localizedDescription + "\n", stderr); exit(1)
        }
    }
}
