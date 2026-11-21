import SwiftUI
import AppKit
import FluentCore

struct TranslationRuntimePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: RuntimePreparationController
    @ViewState<Bool> private var useCrossOver = false
    @ViewState<String> private var crossOver = "/Applications/CrossOver.app"
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.tr("游戏兼容层", "Game translation backends"), systemImage: "cpu").font(.headline)
                if flow.ready { Label(model.tr("原生 Steam 接入已就绪 · 自动管理", "Native Steam integration ready · Managed automatically"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                Picker(model.tr("添加兼容层", "Add a backend"), selection: $useCrossOver) {
                    Text("Wine").tag(false)
                    Text(model.tr("已购买的 CrossOver", "Purchased CrossOver")).tag(true)
                }.pickerStyle(.segmented)
                if useCrossOver {
                    Text(model.tr("使用你自行购买并激活的 CrossOver。Fluent 会自动准备并接入原生 Steam。", "Use CrossOver that you have purchased and activated. Fluent prepares it and connects it to native Steam automatically.")).font(.subheadline)
                    HStack {
                        TextField("CrossOver.app", text: $crossOver)
                        Button(model.tr("选择…", "Choose…")) {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                            panel.canChooseFiles = true; panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { crossOver = url.path }
                        }
                    }
                    Text(model.tr("首次使用需要联网准备必要文件。CrossOver 许可由用户持有。", "The first setup needs an internet connection to prepare the required files. The user supplies the CrossOver license.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.tr("免费 Wine + DXMT，当前提供实验性 DirectX 11 支持。选择后自动准备运行器。", "Free Wine + DXMT with experimental DirectX 11 support. The runtime is prepared automatically after selection.")).font(.subheadline)
                    Link(model.tr("Wine 运行器来源与版本", "Wine runtime source and release"), destination: URL(string: "https://github.com/Drustburn/steamplay-mac/releases/tag/v2026.10.13")!).font(.caption)
                    Text(FreeRuntime.installedRoot(model.paths) == nil ? model.tr("Wine 尚未安装", "Wine is not installed") : model.tr("Wine 已安装", "Wine is installed")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(useCrossOver ? model.tr("使用 CrossOver", "Use CrossOver") : model.tr("使用 Wine", "Use Wine")) {
                        model.chooseTranslationBackend(useCrossOver ? .crossOver(URL(fileURLWithPath: crossOver)) : .wine)
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || (useCrossOver && crossOver.isEmpty))
                    if flow.pendingBackend != nil { Text(model.tr("已记住选择，正在等待自动准备", "Choice saved; automatic preparation is pending")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(model.tr("选择后会设为默认兼容层；已单独指定运行器的游戏保持原选择。Wine 与 CrossOver 使用独立环境，已有存档保留。", "Your choice becomes the default backend. Games with individual runtime settings keep their choices. Wine and CrossOver use separate environments; existing saves are preserved.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
