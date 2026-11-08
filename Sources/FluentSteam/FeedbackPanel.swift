import SwiftUI
import AppKit
import FluentCore

struct FeedbackPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var title = ""
    @ViewState<String> private var steps = ""
    @ViewState<String> private var expected = ""
    @ViewState<String> private var actual = ""
    @ViewState<String> private var preview = ""
    @ViewState<Bool> private var diagnostics = false
    @ViewState<Bool> private var expanded = false
    var body: some View {
        Panel {
            DisclosureGroup(model.tr("反馈与诊断报告", "Feedback and diagnostics"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(model.tr("问题标题", "Issue title"), text: $title).textFieldStyle(.roundedBorder)
                    TextField(model.tr("重现步骤", "Steps to reproduce"), text: $steps, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                    TextField(model.tr("预期结果", "Expected result"), text: $expected, axis: .vertical).textFieldStyle(.roundedBorder)
                    TextField(model.tr("实际结果", "Actual result"), text: $actual, axis: .vertical).textFieldStyle(.roundedBorder)
                    Toggle(model.tr("附带环境与最近 20 条应用事件", "Include environment and 20 recent application events"), isOn: $diagnostics)
                    Text(model.tr("报告先在本地生成，常见凭证和 SteamID 会被遮盖。请检查预览后再自行分享；此版本未配置反馈接收服务器。", "Reports are generated locally with common credentials and SteamIDs redacted. Review before sharing. No feedback server is configured.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.tr("生成预览", "Generate preview")) { generate() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(model.tr("导出 Markdown…", "Export Markdown…")) { export() }.disabled(preview.isEmpty)
                        Button(model.tr("复制报告", "Copy report")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preview, forType: .string) }.disabled(preview.isEmpty)
                    }
                    if !preview.isEmpty { TextEditor(text: $preview).font(.system(.caption, design: .monospaced)).frame(height: 220) }
                }.padding(.top, 10)
            }
        }
    }
    private func generate() {
        preview = FeedbackReport.make(title: title, steps: steps, expected: expected, actual: actual, includeDiagnostics: diagnostics, version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", runtime: model.runtime, recentEvents: model.eventLog)
    }
    private func export() {
        let p = NSSavePanel(); p.nameFieldStringValue = "FluentSteam-feedback.md"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try FileStore.write(Data(preview.utf8), to: url) } catch { model.fail(error) }
    }
}
