import SwiftUI
import FluentCore
struct DownloadPreferencesPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<[DownloadSources.Measurement]> private var results = []
    var body: some View {
        Panel {
            Text(model.tr("下载偏好", "Download preferences")).font(.headline)
            Picker(model.tr("GitHub 公开资源", "Public GitHub assets"), selection: Binding(get: { model.preferences.downloadMirror ?? "direct" }, set: { model.preferences.downloadMirror = $0 })) {
                ForEach(DownloadSources.mirrors, id: \.self) { source in Text(source == "direct" ? model.tr("直连", "Direct") : source).tag(source) }
            }
            Text(model.tr("仅用于公开工具包和已签名更新包；失败或校验不符时回退直连。账号与令牌请求始终直连。", "Applies to public tools and signed updates. Falls back to direct on failure or digest mismatch. Account and token requests use direct connections.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(model.tr("首选 Steam CDN 主机，留空自动选择", "Preferred Steam CDN host; blank for automatic"), text: Binding(get: { model.preferences.preferredCDN ?? "" }, set: { model.preferences.preferredCDN = $0 })).textFieldStyle(.roundedBorder)
                Button(model.tr("测试 GitHub 源", "Test GitHub sources")) { model.run(model.tr("测试下载源", "Test download sources")) { results = await DownloadSources.measureMirrors() } }.disabled(model.busy)
            }
            ForEach(results) { result in
                HStack { Text(result.id == "direct" ? model.tr("直连", "Direct") : result.id); Spacer(); Text(result.error ?? "\(result.milliseconds) ms · \(result.bytes / 1024) KiB").foregroundStyle(result.error == nil ? .secondary : Color.orange) }.font(.caption)
            }
        }
    }
}
