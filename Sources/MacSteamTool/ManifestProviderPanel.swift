import SwiftUI
import MacSteamToolCore

struct ManifestProviderPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<ManifestProviderConfiguration> private var config = .init()
    @ViewState<String> private var ids = ""
    @ViewState<String> private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 5)
            Text(model.tr("内核 Manifest 源热切换", "Kernel manifest provider")).font(.subheadline.bold())
            Picker(model.tr("请求代码来源", "Request-code provider"), selection: $config.mode) {
                Text(model.tr("macSteam 默认", "macSteam default")).tag(ManifestProviderConfiguration.Mode.macsteam)
                Text(model.tr("Steam 原生", "Steam native")).tag(ManifestProviderConfiguration.Mode.steam)
                Text(model.tr("自定义服务", "Custom service")).tag(ManifestProviderConfiguration.Mode.custom)
            }
            if config.mode != .macsteam {
                TextField(model.tr("AppID，逗号分隔", "AppIDs, comma separated"), text: $ids).textFieldStyle(.roundedBorder)
            }
            if config.mode == .custom {
                TextField("https://…/{app}/{depot}/{manifest}", text: $config.url).textFieldStyle(.roundedBorder)
                Text(model.tr("返回十进制 UInt64，或 JSON 的 manifest_request_code / content 字段。最长等待 5 秒；失败及 Beta 分支回退 Steam。", "Accepts a decimal UInt64 or a manifest_request_code / content JSON field. Five-second timeout; failures and beta branches use Steam.")).font(.caption).foregroundStyle(.secondary)
            }
            Button(model.tr("保存并热更新", "Save and apply live")) {
                do {
                    config.apps = Array(Set(ids.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init))).sorted()
                    var current = try RuntimeFeatures.load(paths: model.paths); current.manifestProvider = config; try current.save(paths: model.paths)
                    status = model.tr("已保存；已安装新版扩展的 Steam 会在一秒内读取。", "Saved. Steam with the updated extension reloads it within one second.")
                } catch { model.fail(error) }
            }.disabled(model.busy)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.task {
            do { config = try RuntimeFeatures.load(paths: model.paths).manifestProvider ?? .init(); ids = config.apps.joined(separator: ", ") }
            catch { model.fail(error) }
        }
    }
}
