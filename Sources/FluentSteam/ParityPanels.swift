import SwiftUI
import AppKit
import FluentCore

struct LibrarySourcePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel {
            Picker(model.tr("入库来源", "Library source"), selection: Binding(get: { model.preferences.librarySource ?? "local" }, set: { model.preferences.librarySource = $0; model.savePreferences() })) {
                Text(model.tr("本地密钥生成", "Generate from key cache")).tag("local")
                Text(model.tr("远程 Lua ZIP", "Remote Lua ZIP")).tag("remote")
            }.pickerStyle(.segmented)
            if model.preferences.librarySource == "remote" {
                Picker(model.tr("远程仓库", "Remote repository"), selection: Binding(get: { model.preferences.remotePackageMode ?? "repository" }, set: { model.preferences.remotePackageMode = $0; model.savePreferences() })) {
                    Text(model.tr("原项目仓库（获取链接后下载）", "Upstream repository (resolve download link)")).tag("repository")
                    Text(model.tr("自定义 ZIP URL", "Custom ZIP URL")).tag("direct")
                }
                if model.preferences.remotePackageMode == "direct" {
                TextField("HTTPS ZIP URL · {app}", text: Binding(get: { model.preferences.remotePackageURL ?? RemoteLuaPackage.defaultTemplate }, set: { model.preferences.remotePackageURL = $0 })).textFieldStyle(.roundedBorder)
                Button(model.tr("保存来源", "Save source")) { model.savePreferences() }
                }
                Text(model.tr("按 AppID 下载远程 ZIP，只提取匹配游戏的 Lua，再预览导入。第三方源可能不可用。DLC 由包内容决定。", "Downloads a ZIP by AppID, verifies matching Lua and previews import. Third-party availability varies. DLC depends on the package.")).font(.caption).foregroundStyle(.secondary)
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
    @ViewState<[GameMetadata]> private var popular = []
    @ViewState<[GameMetadata]> private var recommended = []
    @ViewState<String> private var error = ""
    var body: some View {
        Panel {
            HStack {
                Text(model.tr("热门与推荐 · 小黑盒", "Popular & recommended · XiaoHeiHe")).font(.headline)
                Spacer()
                Button(model.tr("刷新榜单", "Refresh charts")) {
                    model.run(model.tr("获取榜单", "Load charts")) {
                        do {
                            let pool = try await DiscoveryCharts.load()
                            popular = Array(pool.prefix(10)); recommended = Array(pool.dropFirst(10).shuffled().prefix(10)); error = ""
                        } catch { self.error = error.localizedDescription; throw error }
                    }
                }.disabled(model.busy)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !popular.isEmpty { chart(model.tr("热门榜单", "Popular"), games: popular); chart(model.tr("为你推荐", "Recommendations"), games: recommended) }
        }
    }
    private func chart(_ title: String, games: [GameMetadata]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.subheadline.bold())
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(games) { game in
                        Button { model.search = String(game.id); model.searchGames() } label: {
                            VStack(alignment: .leading) {
                                Cover(id: game.id, name: game.name, height: 66)
                                Text(game.name).lineLimit(2).font(.caption)
                            }.frame(width: 140)
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }
            }
        }.padding(.top, 8)
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
