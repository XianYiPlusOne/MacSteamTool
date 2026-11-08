import SwiftUI
import FluentCore

struct RuntimeUpdatePanel: View {
    @EnvironmentObject var model: AppModel
    let provider: String
    @Binding var companion: String
    @ViewState<OfficialRuntimeRelease?> private var release = nil
    @ViewState<PreparedRuntime?> private var prepared = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider == "macsteam" ? "macSteam" : "NotProton").font(.subheadline.bold())
                Text(model.tr("已安装：", "Installed: ") + (provider == "macsteam" ? model.runtime.macSteamVersion : model.runtime.notProtonVersion)).foregroundStyle(.secondary)
                if let release { Text(model.tr("官方版本：", "Official release: ") + release.version) }
                Spacer()
                Button(model.tr("检查官方更新", "Check official release")) {
                    model.run(model.tr("查询官方运行器", "Check official runtime")) {
                        release = try await OfficialRuntimeUpdates.check(provider, engine: model.engineExecutable)
                        prepared = nil
                    }
                }.disabled(model.busy)
                if let release {
                    Link(model.tr("发布说明", "Release notes"), destination: URL(string: release.releaseURL)!)
                    Button(model.tr("下载并校验", "Download & verify")) {
                        model.run(model.tr("下载官方运行器", "Download official runtime")) {
                            let result = try await OfficialRuntimeUpdates.prepare(release, engine: model.engineExecutable, cache: model.paths.cache.appendingPathComponent("OfficialRuntimes"))
                            prepared = result
                            if result.supportedSteamBuilds.contains(model.runtime.build) { companion = result.application.path }
                        }
                    }.disabled(model.busy)
                }
            }.font(.caption)
            if let prepared {
                Text(prepared.supportedSteamBuilds.contains(model.runtime.build)
                     ? model.tr("已校验并选为安装来源，包含当前 Steam 版本的兼容数据。退出 Steam 后可点上方“安装 / 更新”。", "Verified and selected as the installation source. Includes a profile for the current Steam build. Quit Steam, then use Install / update above.")
                     : model.tr("下载已校验，但未找到当前 Steam 版本的兼容数据，未更换安装来源。请先查看发布说明。", "Download verified, but no profile matches the current Steam build. The installation source was kept. Review the release notes first.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
