import Foundation
import FluentCore

extension AppModel {
    func reconcileAutomaticAchievements(force: Bool = false) {
        guard !testing, !busy, preferences.automaticallyPrepareAchievements != false,
              automaticAchievementsTask == nil,
              force || Date().timeIntervalSince(automaticAchievementsChecked) >= 15 else { return }
        automaticAchievementsChecked = Date()
        let pending = paths
        automaticAchievementsTask = Task {
            defer { automaticAchievementsTask = nil }
            do {
                let report = try await AutomaticAchievements.process(paths: pending, force: force) { id in
                    try await AchievementRepair.fetchSchema(appID: id, paths: pending,
                        worker: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluentSteamWorker"))
                }
                guard paths.steam == pending.steam, paths.data == pending.data, paths.config == pending.config else { return }
                publishAutomaticAchievements(report)
            } catch is CancellationError { }
            catch { automaticAchievementsStatus = error.localizedDescription }
        }
    }
    func publishAutomaticAchievements(_ report: AutomaticAchievements.Report) {
        func ids(_ values: [Int]) -> String { values.map(String.init).joined(separator: ", ") }
        var messages: [String] = []
        if !report.applied.isEmpty {
            let text = tr("兼容成就已自动准备：", "Compatibility achievements prepared: ") + ids(report.applied)
            log(text); messages.append(text)
        }
        if !report.waitingForLogin.isEmpty { messages.append(tr("等待 Steam 登录后获取成就定义：", "Waiting for Steam sign-in to fetch definitions: ") + ids(report.waitingForLogin)) }
        if !report.waitingForExit.isEmpty {
            needsRestart = true
            messages.append(tr("定义已取得，退出 Steam 后自动应用：", "Definitions ready; apply after Steam exits: ") + ids(report.waitingForExit))
        }
        for id in report.failures.keys.sorted() { messages.append("App \(id): " + report.failures[id]!) }
        automaticAchievementsStatus = messages.joined(separator: "\n")
    }
}
