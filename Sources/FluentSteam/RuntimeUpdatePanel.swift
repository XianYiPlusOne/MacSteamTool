import SwiftUI
import FluentCore

struct RuntimeUpdatePanel: View {
    @EnvironmentObject var model: AppModel
    let provider: String
    @Binding var companion: String
    @ViewState<OfficialRuntimeRelease?> private var release = nil
    @ViewState<PreparedRuntime?> private var prepared = nil
    var displayedRelease: OfficialRuntimeRelease? { release ?? model.runtimeReleases[provider] }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider == "macsteam" ? "macSteam" : "NotProton").font(.subheadline.bold())
                Text(model.tr("已安装：", "Installed: ") + (provider == "macsteam" ? model.runtime.macSteamVersion : model.runtime.notProtonVersion)).foregroundStyle(.secondary)
                if let release = displayedRelease { Text(model.tr("官方版本：", "Official release: ") + release.version) }
                Spacer()
                Button(model.tr("检查官方更新", "Check official release")) {
                    model.run(model.tr("查询官方运行器", "Check official runtime")) {
                        release = try await OfficialRuntimeUpdates.check(provider, engine: model.engineExecutable)
                        if let release { model.runtimeReleases[provider] = release }
                        prepared = nil
                    }
                }.disabled(model.busy)
                if let release = displayedRelease {
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
            if let release = displayedRelease {
                DisclosureGroup(model.tr("应用内发布说明", "Release notes")) {
                    ReleaseNotes(markdown: release.notes.flatMap { $0.isEmpty ? nil : $0 } ?? model.tr("此版本未提供可读取的发布说明，可打开官方发布页面查看。", "No readable release notes were supplied. Open the official release page for details."))
                }
            }
            if let prepared {
                Text(prepared.supportedSteamBuilds.contains(model.runtime.build)
                     ? model.tr("已校验并选为安装来源，包含当前 Steam 版本的兼容数据。退出 Steam 后可点上方“安装 / 更新”。", "Verified and selected as the installation source. Includes a profile for the current Steam build. Quit Steam, then use Install / update above.")
                     : model.tr("下载已校验，但未找到当前 Steam 版本的兼容数据，未更换安装来源。请先查看发布说明。", "Download verified, but no profile matches the current Steam build. The installation source was kept. Review the release notes first.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension AppModel {
    var runtimeUpdateProviders: [String] {
        runtimeReleases.keys.sorted().filter { provider in
            let installed = provider == "macsteam" ? runtime.macSteamVersion : runtime.notProtonVersion
            guard let release = runtimeReleases[provider], let version = TextUtil.matches(#"[0-9]+(?:\.[0-9]+){1,3}"#, installed).first?.first else { return false }
            return release.version.compare(version, options: .numeric) == .orderedDescending
        }
    }
    func checkRuntimeUpdates() async {
        guard !testing else { return }
        var errors: [String] = []
        for provider in ["macsteam", "notproton"] {
            do { runtimeReleases[provider] = try await OfficialRuntimeUpdates.check(provider, engine: engineExecutable) }
            catch { errors.append(provider + ": " + error.localizedDescription) }
        }
        runtimeUpdateStatus = errors.joined(separator: "\n")
    }
}
