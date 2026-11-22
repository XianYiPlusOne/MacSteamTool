import SwiftUI
import MacSteamToolCore

struct CachePanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var status = ""
    @ViewState<Bool> private var confirm = false
    var body: some View {
        Panel {
            Text(model.tr("缓存维护", "Cache maintenance")).font(.headline)
            Text(model.tr("清理元数据、密钥缓存、临时补丁和下载的内核安装包。保留游戏清单、存档、备份、已下载工具及 Steam 缓存。", "Clears metadata, key cache, temporary patches and runtime installers. Keeps game lists, saves, backups, downloaded tools and Steam cache.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(model.tr("统计可清理空间", "Calculate disposable cache")) { measure() }
                Button(model.tr("清理缓存…", "Clear cache…")) { confirm = true }
                Text(status).font(.caption)
            }.disabled(model.busy)
        }.confirmationDialog(model.tr("清理可重新下载的应用缓存？", "Clear downloadable app cache?"), isPresented: $confirm) {
            Button(model.tr("清理", "Clear"), role: .destructive) {
                model.run(model.tr("清理应用缓存", "Clear app cache"), cancellable: false) {
                    model.stopManifestMonitor(); model.metadataTask?.cancel(); model.metadataTask = nil
                    let paths = model.paths
                    let result = try await Task.detached { try CacheMaintenance.clear(paths: paths) }.value
                    model.metadata.removeAll(); status = description(result); model.refresh()
                }
            }
        }
    }
    private func description(_ result: CacheMaintenance.Summary) -> String { "\(result.entries) " + model.tr("个文件", "files") + " · " + ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file) }
    private func measure() {
        let paths = model.paths
        model.run(model.tr("统计缓存", "Measure cache")) { status = description(try await Task.detached { try CacheMaintenance.summary(paths: paths) }.value) }
    }
}
