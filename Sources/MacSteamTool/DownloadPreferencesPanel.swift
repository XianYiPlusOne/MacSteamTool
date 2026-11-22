import SwiftUI
import MacSteamToolCore
struct DownloadPreferencesPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<[DownloadSources.Measurement]> private var results = []
    @ViewState<[DownloadSources.Measurement]> private var cdnResults = []
    @ViewState<[DownloadSources.Measurement]> private var manifestResults = []
    @ViewState<String> private var depot = ""
    @ViewState<String> private var manifest = ""
    var body: some View {
        Panel {
            Text(model.tr("下载偏好", "Download preferences")).font(.headline)
            Picker(model.tr("GitHub 公开资源", "Public GitHub assets"), selection: Binding(get: { model.preferences.downloadMirror ?? "direct" }, set: { model.preferences.downloadMirror = $0 })) {
                ForEach(DownloadSources.mirrors, id: \.self) { source in Text(source == "direct" ? model.tr("直连", "Direct") : source).tag(source) }
            }
            Text(model.tr("离线工具包优先使用所选来源，下载或校验失败会尝试直连和其他镜像。此偏好也用于已签名更新包。账号与令牌请求始终直连。", "Offline tools try the preferred source first, then direct and other mirrors on download or verification failure. Signed updates also use this preference. Account and token requests use direct connections.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(model.tr("首选 Steam CDN 主机，留空自动选择", "Preferred Steam CDN host; blank for automatic"), text: Binding(get: { model.preferences.preferredCDN ?? "" }, set: { model.preferences.preferredCDN = $0 })).textFieldStyle(.roundedBorder)
                Button(model.tr("测试 GitHub 源", "Test GitHub sources")) { model.run(model.tr("测试下载源", "Test download sources")) { results = await DownloadSources.measureMirrors() } }.disabled(model.busy)
            }
            ForEach(results) { result in
                HStack { Text(result.id == "direct" ? model.tr("直连", "Direct") : result.id); Spacer(); Text(result.error ?? "\(result.milliseconds) ms · \(result.bytes / 1024) KiB").foregroundStyle(result.error == nil ? .secondary : Color.orange) }.font(.caption)
            }
            Divider()
            Button(model.tr("封面 CDN 测速", "Test cover CDNs")) { model.run(model.tr("测试封面 CDN", "Testing cover CDNs")) { cdnResults = await DownloadSources.measureImageCDNs() } }.disabled(model.busy)
            measurements(cdnResults)
            Text(model.tr("测速使用公开封面，显示耗时与数据量；不代表游戏下载带宽。", "Tests a public cover and reports latency and size; this is not a game download bandwidth test.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Depot ID", text: $depot).textFieldStyle(.roundedBorder)
                TextField("Manifest ID", text: $manifest).textFieldStyle(.roundedBorder)
                Menu(model.tr("从已安装游戏填入", "Use an installed game")) {
                    ForEach(model.games.filter { $0.installed != nil }) { game in
                        Menu(game.name) {
                            ForEach((game.installed?.depots.keys.sorted() ?? []), id: \.self) { id in
                                Button(String(id)) { depot = String(id); manifest = game.installed?.depots[id] ?? "" }
                            }
                        }
                    }
                }
            }
            Button(model.tr("逐个检测 Manifest 源", "Test each manifest source")) {
                model.run(model.tr("检测 Manifest 源", "Testing manifest sources")) {
                    manifestResults = try await DownloadSources.probeManifests(depot: Int(depot) ?? 0, manifest: manifest, preferred: model.preferences.manifestURL, content: model.content)
                }
            }.disabled(model.busy || depot.isEmpty || manifest.isEmpty)
            measurements(manifestResults)
            Text(model.tr("按指定清单检测每个源，校验真实内容，不写入 Steam 缓存。单款游戏失败不能代表服务商整体不可用。", "Checks each source against the selected manifest and validates the content without writing Steam cache. Failure for one game does not prove a provider is unavailable for all games.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func measurements(_ values: [DownloadSources.Measurement]) -> some View {
        ForEach(values) { result in
            VStack(alignment: .leading) {
                Text(result.id).lineLimit(1)
                Text(result.error ?? "\(result.milliseconds) ms · \(result.bytes / 1024) KiB").foregroundStyle(result.error == nil ? .secondary : Color.orange).lineLimit(3)
            }.font(.caption).textSelection(.enabled)
        }
    }
}
