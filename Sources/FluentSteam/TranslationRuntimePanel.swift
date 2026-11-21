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
                    Text(model.tr("首次准备会下载 Wine、DXVK 和 D3DMetal。每个游戏可在 Steam「属性 → 兼容性」里选择图形后端、高分辨率和其他选项。", "Setup downloads Wine, DXVK and D3DMetal. Choose a renderer, High Resolution and other options in each game’s Steam Properties → Compatibility.")).font(.subheadline)
                    Link(model.tr("Wine 运行器来源与版本", "Wine runtime source and release"), destination: URL(string: "https://github.com/Drustburn/steamplay-mac/releases/tag/v2026.10.13")!).font(.caption)
                    Text(FreeRuntime.installedRoot(model.paths) == nil ? model.tr("Wine 尚未安装", "Wine is not installed") : FreeRuntime.graphicsReady(model.paths) ? model.tr("Wine 已安装", "Wine is installed") : model.tr("当前为旧版 Wine。选择「使用 Wine」更新图形组件。", "Select Use Wine to update this installation’s graphics components.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(useCrossOver ? model.tr("使用 CrossOver", "Use CrossOver") : model.tr("使用 Wine", "Use Wine")) {
                        model.chooseTranslationBackend(useCrossOver ? .crossOver(URL(fileURLWithPath: crossOver)) : .wine)
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.busy || (useCrossOver && crossOver.isEmpty))
                    if flow.pendingBackend != nil { Text(model.tr("已记住选择，正在等待自动准备", "Choice saved; automatic preparation is pending")).font(.caption).foregroundStyle(.secondary) }
                }
                RuntimeCompatibilityDefaults(useCrossOver: useCrossOver, state: flow.state)
                Text(model.tr("选择后会设为默认兼容层；已单独指定运行器的游戏保持原选择。Wine 与 CrossOver 使用独立环境，已有存档保留。", "Your choice becomes the default backend. Games with individual runtime settings keep their choices. Wine and CrossOver use separate environments; existing saves are preserved.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RuntimeCompatibilityDefaults: View {
    @EnvironmentObject var model: AppModel
    let useCrossOver: Bool
    let state: RuntimePreparationController.State
    @ViewState<[ContainerBackend]> private var backends = []
    @ViewState<String> private var selectedID = ""
    @ViewState<[String: String]> private var settings = [:]

    var body: some View {
        Group {
            if let backend = backends.first(where: { $0.id == selectedID }) {
                let config = RunnerCompatibility(backend: backend, paths: model.paths)
                let renderer = settings["CX_GRAPHICS_BACKEND"].flatMap(GraphicsRenderer.init(rawValue:)) ?? .automatic
                DisclosureGroup(model.tr("默认兼容性设置", "Default compatibility settings")) {
                    VStack(alignment: .leading, spacing: 9) {
                        if backends.count > 1 {
                            Picker(model.tr("运行器版本", "Runner version"), selection: $selectedID) {
                                ForEach(backends) { Text($0.name).tag($0.id) }
                            }
                        }
                        Text(backend.isWine
                             ? model.tr("适用于 Wine 和沿用 Rosetta 默认设置的 CrossOver 运行器。", "Applies to Wine and CrossOver runners that inherit Rosetta defaults.")
                             : model.tr("适用于这个 CrossOver 版本。", "Applies to this CrossOver version."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(config.options(for: renderer)) { option in
                            let label = model.tr(option.chinese, option.english)
                            let binding = Binding(get: { option.value(in: settings) }, set: { value in
                                do { try config.set(value, for: option); settings = try config.settings() }
                                catch { model.fail(error) }
                            })
                            if let choices = option.choices {
                                Picker(label, selection: binding) {
                                    ForEach(choices, id: \.self) { Text(choiceName($0)).tag($0) }
                                }
                            } else {
                                Toggle(label, isOn: Binding(get: { binding.wrappedValue == "1" },
                                                           set: { binding.wrappedValue = $0 ? "1" : "0" }))
                            }
                        }
                        .disabled(model.busy || model.steamRunning)
                        Text(model.tr("退出 Steam 后可修改默认值，下次启动游戏时生效。单个游戏可在 Steam 的「属性 → 兼容性」中覆盖。", "Quit Steam to edit defaults. They apply on the next game launch. Override them per game in Steam Properties → Compatibility."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 5)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: useCrossOver) { _, _ in reload() }
        .onChange(of: state) { _, _ in reload() }
        .onChange(of: model.steamRunning) { _, _ in reload() }
        .onChange(of: selectedID) { _, _ in readSettings() }
    }

    private func choiceName(_ value: String) -> String {
        if value.isEmpty { return model.tr("关闭", "Off") }
        if value == "auto" { return model.tr("自动", "Automatic") }
        return GraphicsRenderer(rawValue: value)?.name ?? value
    }
    private func reload() {
        do {
            backends = try GameContainers.backends(model.paths).filter {
                useCrossOver ? !$0.isWine : $0.isWine && FreeRuntime.graphicsReady(model.paths)
            }
            if !backends.contains(where: { $0.id == selectedID }) { selectedID = backends.first?.id ?? "" }
            readSettings()
        } catch { model.fail(error) }
    }
    private func readSettings() {
        guard let backend = backends.first(where: { $0.id == selectedID }) else { return }
        do { settings = try RunnerCompatibility(backend: backend, paths: model.paths).settings() }
        catch { model.fail(error) }
    }
}
