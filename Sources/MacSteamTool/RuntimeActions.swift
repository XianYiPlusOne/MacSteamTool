import SwiftUI
import AppKit
import MacSteamToolCore

struct RuntimeActions: View {
    @EnvironmentObject var model: AppModel
    @ViewState<[RuntimeBackup]> private var backups = []
    @ViewState<RuntimeBackup?> private var restore = nil
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.tr("自动维护与恢复", "Automatic maintenance and recovery")).font(.headline)
                Text(model.tr("原生 Steam 接入由程序自动准备和修复。每次更新接入组件都会保留恢复记录。", "Native Steam integration is prepared and repaired automatically. Each integration update retains a recovery record.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(model.tr("可恢复的安装备份", "Installation backups")).font(.subheadline.bold())
                    Spacer()
                    Button(model.tr("刷新", "Refresh")) { reload() }
                    Button(model.tr("打开目录", "Open folder")) { model.openFolder(model.paths.data.appendingPathComponent("RuntimeBackups")) }
                }
                if backups.isEmpty { Text(model.tr("安装后将在此列出完整备份。", "Full backups appear here after an installation.")).font(.caption).foregroundStyle(.secondary) }
                ForEach(backups.prefix(8)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.isNotProton ? model.tr("游戏启动接入备份", "Game launch integration backup") : model.tr("Steam 接入备份", "Steam integration backup")).font(.caption.bold())
                            Text(item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            if item.interrupted { Text(model.tr("安装中断 · 可备份当前状态后恢复", "Interrupted · current state will be backed up before recovery")).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button(model.tr("恢复…", "Restore…")) { restore = item }.disabled(model.busy || model.steamRunning)
                    }
                }
            }
        }
        .task { reload() }
        .confirmationDialog(restore?.interrupted == true ? model.tr("恢复中断的安装？将先完整备份当前状态，再还原所选备份；游戏和前缀不会被更改。", "Recover interrupted installation? The current state is backed up in full first. Games and prefixes are not changed.") : model.tr("恢复此备份？若安装后文件已发生变化，将停止恢复。", "Restore this backup? Recovery stops if installed files have changed since then."), isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } })) {
            if let item = restore {
                Button(model.tr("恢复备份", "Restore backup")) { perform(restoring: item); restore = nil }
            }
        }
    }
    private func reload() { backups = RuntimeInstaller.backups(model.paths) }
    private func perform(restoring: RuntimeBackup) {
        let paths = model.paths
        model.run(model.tr("恢复 Steam 接入", "Restore Steam integration"), cancellable: false) {
            defer { reload() }
            let backup = try await RuntimeInstaller.run(paths: paths, restoring: restoring) { text in
                await MainActor.run { model.progress = text }
            }
            model.log(model.tr("安装备份：", "Installation backup: ") + backup.path)
            model.needsRestart = true; model.refresh(); reload()
        }
    }
}
