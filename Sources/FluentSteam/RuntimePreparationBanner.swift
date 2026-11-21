import SwiftUI
import FluentCore

struct RuntimePreparationBanner: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: RuntimePreparationController
    @ViewState<Bool> private var consent = false
    var body: some View {
        if !flow.ready {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if flow.working || flow.state == .checking { ProgressView().controlSize(.small) }
                    Text(title).font(.subheadline)
                    Spacer()
                    if flow.state == .waitingForSteam {
                        Button(model.tr("退出 Steam 并继续", "Quit Steam and continue")) { model.quitSteamForPreparation() }
                    }
                    if case .failed = flow.state {
                        Button(model.tr("重试", "Retry")) { model.reconcileRuntimePreparation(retry: true) }.disabled(model.busy)
                    }
                }
                if flow.state == .waitingForSteam {
                    Text(model.tr("请先保存游戏。Steam 退出后会自动继续，已选择的兼容层会保留。", "Save your game first. Preparation resumes automatically when Steam closes; your backend choice is retained.")).font(.caption).foregroundStyle(.secondary)
                }
                if flow.working && !flow.detail.isEmpty {
                    Text(flow.detail).font(.caption).foregroundStyle(.secondary)
                }
                if flow.state == .needsRosetta {
                    Text(model.tr("此 Mac 需要 Rosetta 2。继续后由 macOS 请求安装授权。", "This Mac needs Rosetta 2. macOS will request installation authorization when you continue.")).font(.caption)
                    Toggle(model.tr("我已阅读并同意 Apple 的 Rosetta 2 许可", "I have read and accept Apple's Rosetta 2 license"), isOn: $consent)
                    HStack {
                        Link(model.tr("Apple 软件许可", "Apple software licenses"), destination: URL(string: "https://www.apple.com/legal/sla/")!)
                        Button(model.tr("授权并继续", "Authorize and continue")) { Task { await flow.grantRosettaConsent() } }.disabled(!consent)
                    }.font(.caption)
                    if !flow.detail.isEmpty { Text(flow.detail).font(.caption).foregroundStyle(.secondary) }
                }
                if case .failed(let error) = flow.state {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(12).background(Palette.accent.opacity(0.08)).padding(.horizontal, 30)
        }
    }
    private var title: String {
        switch flow.state {
        case .checking: model.tr("正在检查游戏环境", "Checking your gaming environment")
        case .preparing, .installing: model.tr("正在自动准备游戏环境", "Preparing your gaming environment automatically")
        case .waitingForSteam: model.tr("需要退出 Steam 以完成准备", "Quit Steam to finish preparation")
        case .needsRosetta: model.tr("需要系统授权", "System authorization needed")
        case .ready: model.tr("游戏环境已就绪", "Gaming environment ready")
        case .failed: model.tr("自动准备暂未完成", "Automatic preparation could not finish")
        }
    }
}
