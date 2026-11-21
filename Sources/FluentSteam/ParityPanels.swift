import SwiftUI
import AppKit
import FluentCore

struct LibraryFallbackSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        DisclosureGroup(model.tr("备用入库源（高级）", "Alternate library source (advanced)")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(model.tr("远程仓库", "Remote repository"), selection: Binding(get: { model.preferences.remotePackageMode ?? "repository" }, set: { model.preferences.remotePackageMode = $0 })) {
                    Text(model.tr("默认仓库", "Default repository")).tag("repository")
                    Text(model.tr("自定义 ZIP URL", "Custom ZIP URL")).tag("direct")
                }
                if model.preferences.remotePackageMode == "direct" {
                    TextField("HTTPS ZIP URL · {app}", text: Binding(get: { model.preferences.remotePackageURL ?? RemoteLuaPackage.defaultTemplate }, set: { model.preferences.remotePackageURL = $0 })).textFieldStyle(.roundedBorder)
                }
                Text(model.tr("入库时自动按需使用，通常无需修改。自定义地址必须使用 HTTPS，并以 {app} 代表 AppID。", "Used automatically when needed. Usually no changes are necessary. Custom URLs require HTTPS and {app} for the AppID.")).font(.caption).foregroundStyle(.secondary)
                Text(model.tr("程序会先检查 Steam 本机的 Depot 缓存。远程仓库未补齐时，再尝试 Internet Archive、KeySteam、ManifestHub3 和 Steam-lua 镜像。", "Import checks Steam's local depot cache first. If the remote repository leaves gaps, it tries Internet Archive, KeySteam, ManifestHub3, and the Steam-lua mirror.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct ManifestHubPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var key = ""
    @ViewState<String> private var status = ""
    var body: some View {
        Panel {
            Picker(model.tr("监听与手动获取来源", "Monitor and manual download source"), selection: Binding(get: { model.preferences.manifestSource ?? "code" }, set: { model.preferences.manifestSource = $0; model.savePreferences(stopManifest: false) })) {
                Text("Code / CDN").tag("code"); Text("ManifestHub API Key").tag("hub")
            }.pickerStyle(.segmented).disabled(model.busy)
            if model.preferences.manifestSource == "hub" {
                HStack {
                    SecureField("ManifestHub API Key", text: $key).textFieldStyle(.roundedBorder)
                    Button(model.tr("保存 Key", "Save key")) {
                        do { model.stopManifestMonitor(source: "hub"); try ManifestHubCredential.save(key); key = ""; updateStatus() } catch { model.fail(error) }
                    }.disabled(key.isEmpty)
                    Button(model.tr("忘记 Key", "Forget key")) {
                        do { model.stopManifestMonitor(source: "hub"); try ManifestHubCredential.remove(); updateStatus() } catch { model.fail(error) }
                    }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text(model.tr("Key 保存在钥匙串。本地有效期为保存后 24 小时，不代表服务器承诺的期限；服务端拒绝时停止 Hub 监听，不切换到其他来源。", "Key is kept in Keychain. Local validity is 24 hours after saving, not a server expiry guarantee. A rejected key stops Hub monitoring without switching sources.")).font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { updateStatus() }
    }
    private func updateStatus() {
        do {
            if let credential = try ManifestHubCredential.load() { status = model.tr("本地有效至：", "Local validity until: ") + credential.expiry.formatted(date: .numeric, time: .shortened) }
            else { status = model.tr("尚未保存 Key", "No saved key") }
        } catch { status = error.localizedDescription }
    }
}
struct DiscoveryChartsPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var isExpanded: Bool
    var body: some View { DiscoveryChartsContent(flow: model.charts, isExpanded: $isExpanded).task { model.charts.load() } }
}
private struct DiscoveryChartsContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: DiscoveryChartsFlow
    @Binding var isExpanded: Bool
    var body: some View {
        Panel {
            HStack {
                Button { withAnimation { isExpanded.toggle() } } label: {
                    Label(model.tr("热门榜单 · 小黑盒", "Popular · XiaoHeiHe"), systemImage: isExpanded ? "chevron.down" : "chevron.right").font(.headline)
                }.buttonStyle(.plain).accessibilityValue(model.tr(isExpanded ? "已展开" : "已折叠", isExpanded ? "Expanded" : "Collapsed"))
                if flow.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.tr("刷新榜单", "Refresh charts")) { flow.load() }.disabled(flow.loading || flow.loadingMore)
            }
            if isExpanded {
                if flow.loading {
                    Text(model.tr("正在获取最新热门榜单…", "Loading the latest popular games…")).font(.caption).foregroundStyle(.secondary)
                } else if let updated = flow.updated {
                    Text(model.tr("更新于 · ", "Updated · ") + updated.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                if !flow.error.isEmpty {
                    Text(model.tr("榜单加载失败：", "Could not load charts: ") + flow.error).font(.caption).foregroundStyle(.secondary)
                }
                if !flow.popular.isEmpty { DiscoveryChartRow(flow: flow, title: model.tr("热门榜单", "Popular"), games: flow.popular) }
            }
        }
    }
}
struct ReleaseNotes: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                let heading = line.hasPrefix("#")
                let content = heading ? line.drop(while: { $0 == "#" || $0 == " " }).description : line
                Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
                    .font(heading ? .headline : .caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
