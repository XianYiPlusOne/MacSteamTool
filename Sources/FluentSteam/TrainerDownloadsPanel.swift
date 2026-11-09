import SwiftUI
import AppKit
import FluentCore

struct TrainerDownloadsPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<URL?> private var deleting: URL?
    @ViewState<Bool> private var confirmation = false
    var files: [URL] {
        FileStore.files(model.paths.data.appendingPathComponent("Downloads"))
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    var body: some View {
        Panel {
            Text(model.tr("已下载文件", "Downloaded files")).font(.headline)
            if files.isEmpty { Text(model.tr("暂无下载文件。", "No downloads yet.")).font(.caption).foregroundStyle(.secondary) }
            ForEach(files, id: \.path) { file in
                HStack {
                    Text(file.lastPathComponent).font(.caption).lineLimit(1)
                    Spacer()
                    Button(model.tr("显示", "Reveal")) { model.reveal(file) }
                    Button(model.tr("解压 / 打开", "Extract / open")) { NSWorkspace.shared.open(file) }
                    Button(model.tr("移到废纸篓…", "Move to Trash…"), role: .destructive) { deleting = file; confirmation = true }
                }
            }
        }
        .confirmationDialog(model.tr("将此下载文件移到废纸篓？", "Move this download to Trash?"), isPresented: $confirmation) {
            if let deleting {
                Button(deleting.lastPathComponent, role: .destructive) {
                    NSWorkspace.shared.recycle([deleting]) { _, error in
                        Task { @MainActor in if let error { model.fail(error) }; model.refresh() }
                    }
                }
            }
        }
    }
}
struct TrainerAgentPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel {
            Toggle(model.tr("独立后台监控，并在登录 macOS 时启动", "Independent monitor, start at macOS login"), isOn: Binding(get: { model.preferences.independentTrainerMonitor == true }, set: { model.preferences.independentTrainerMonitor = $0; model.savePreferences() })).disabled(model.busy)
            Text(model.tr("启用后由独立后台进程监控已配置为自动启动的修改器，退出主程序仍生效。关闭此选项会卸载登录项并恢复应用内监控；不会启用尚未配置的修改器。移动应用后请重新关闭再开启。", "A separate background process monitors trainers configured for auto-launch, even after this app quits. Disabling removes the login item and restores in-app monitoring. Unconfigured trainers remain inactive. Re-enable after moving the application.")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
extension AppModel {
    func trainerShortcut(_ binding: TrainerBinding) {
        do {
            guard !testing else { return }
            let desktop = try FileStore.fm.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let file = try TrainerShortcuts.create(binding, directory: desktop); reveal(file)
        } catch { fail(error) }
    }
    func handleShortcut(_ url: URL) {
        if !bootstrapFinished { pendingTrainerShortcut = url; return }
        guard let id = TrainerShortcuts.bindingID(url), let binding = preferences.trainers.first(where: { $0.id == id }) else { return }
        launchTrainer(binding)
    }
}
