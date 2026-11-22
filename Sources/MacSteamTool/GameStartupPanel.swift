import SwiftUI
import MacSteamToolCore

struct GameStartupPanel: View {
    @EnvironmentObject var model: AppModel
    let game: InstalledGame
    @ViewState<GameStartupDiagnostics.Report?> private var report: GameStartupDiagnostics.Report?
    var body: some View {
        Panel {
            HStack {
                Text(model.tr("游戏启动检查", "Game startup check")).font(.headline)
                Spacer()
                Button(model.tr("检查最近启动", "Check latest startup")) { report = GameStartupDiagnostics.inspect(game) }
            }
            if let report {
                Text(summary(report.status)).font(.caption).foregroundStyle(report.status == .failed ? Palette.amber : .secondary)
                if let date = report.modifiedAt { Text(model.tr("日志更新时间：", "Log last modified: ") + date.formatted()).font(.caption).foregroundStyle(.secondary) }
                Text(model.tr("结果来自该游戏最近一次日志，不代表它当前正在运行。初始化成功也不保证所有成就或通知都正常。", "This describes the game's latest log, not a current running session. Successful initialization alone does not verify achievements or notifications.")).font(.caption).foregroundStyle(.secondary)
                if !report.observations.isEmpty { Text(report.observations.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let log = report.log { Button(model.tr("在 Finder 显示日志", "Reveal log in Finder")) { model.reveal(log) } }
            } else {
                Text(model.tr("读取此游戏的启动日志，区分 Steam 连接失败和成就记录问题；不修改游戏、成就或存档。", "Read this game's startup log to distinguish Steam initialization failures from achievement issues. No game, achievement or save changes.")).font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of: game.id) { _, _ in report = nil }
    }
    private func summary(_ status: GameStartupDiagnostics.Status) -> String {
        switch status {
        case .failed: return model.tr("这次启动未能连接 Steam API，可能影响成就与创意工坊。先保存并正常退出，再从 Steam 重开；反复出现时保留日志用于排查。", "Steam API initialization failed in this launch, potentially affecting achievements and Workshop. Save, exit normally and reopen from Steam. Keep the log if this recurs.")
        case .initialized: return model.tr("日志确认游戏的 Steam API 已初始化。", "The log confirms the game's Steam API initialized.")
        case .unknown: return model.tr("已找到日志，但没有明确的 Steam 初始化结果，无法判断。", "A log was found, but it contains no recognized Steam initialization result.")
        case .unavailable: return model.tr("未找到此游戏可识别的 Unity 启动日志；这不表示游戏启动失败。", "No recognized Unity startup log found for this game; this does not indicate a launch failure.")
        }
    }
}
