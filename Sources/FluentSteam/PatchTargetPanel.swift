import SwiftUI
import AppKit
import FluentCore

struct PatchTargetPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var appID: Int
    @Binding var customRoot: URL?
    @ViewState<String> private var searchText = ""
    @ViewState<String> private var manualID = ""
    @ViewState<[GameMetadata]> private var matches = []
    @ViewState<Bool> private var searched = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let customRoot {
                Text(customRoot.path).font(.caption).textSelection(.enabled)
                HStack {
                    TextField(model.tr("游戏名称（默认使用文件夹名）", "Game title (defaults to folder name)"), text: $searchText).textFieldStyle(.roundedBorder).onSubmit(search)
                    Button(model.tr("查询 AppID", "Find AppID"), action: search).disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("AppID", text: $manualID).textFieldStyle(.roundedBorder).frame(width: 110).onChange(of: manualID) { _, value in appID = TextUtil.validID(value) ?? 0 }
                }
                ForEach(matches) { match in
                    HStack { Text("\(match.name) · \(match.id)").font(.caption); Spacer(); Button(model.tr("选择", "Select")) { manualID = String(match.id); appID = match.id; matches = [] } }
                }
                if searched && matches.isEmpty && appID == 0 {
                    Text(model.tr("未找到候选，请调整名称或手动填写 AppID。", "No matches. Adjust the title or enter the AppID manually.")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Picker(model.tr("目标游戏", "Target game"), selection: $appID) {
                    Text(model.tr("选择已安装游戏", "Choose installed game")).tag(0)
                    ForEach(model.games.filter { $0.installed != nil }) { Text("\($0.name) · \($0.id)").tag($0.id) }
                }
            }
            HStack {
                Button(model.tr("选择游戏文件夹…", "Choose game folder…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let folder = panel.url {
                        customRoot = folder; searchText = folder.lastPathComponent; manualID = ""; appID = 0; matches = []; searched = false
                    }
                }
                if customRoot != nil { Button(model.tr("返回已安装游戏", "Use installed game")) { customRoot = nil; appID = 0; matches = [] } }
            }
        }.disabled(model.busy)
    }
    private func search() {
        let query = searchText
        model.run(model.tr("查询游戏 AppID", "Find game AppID")) { matches = try await model.api.search(query, language: model.language); searched = true }
    }
}
