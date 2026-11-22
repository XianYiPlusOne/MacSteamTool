import SwiftUI

extension RuntimePreparationController {
    func statusTitle(_ model: AppModel) -> String {
        switch state {
        case .checking: model.tr("正在检查运行环境", "Checking the runtime")
        case .preparing: model.tr("正在准备安装文件", "Preparing setup files")
        case .installing: model.tr("正在安装运行环境", "Installing the runtime")
        case .waitingForSteam: model.tr("等待 Steam 退出", "Waiting for Steam to quit")
        case .needsRosetta: model.tr("需要授权安装 Rosetta 2", "Rosetta 2 needs approval")
        case .failed: model.tr("环境准备未完成", "Runtime setup incomplete")
        case .ready: ready ? model.tr("运行环境已就绪", "Runtime ready") : model.tr("正在检查所选兼容层", "Checking the selected backend")
        }
    }
}

struct RuntimeSetupPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: RuntimePreparationController
    @ViewState<Bool> private var consent = false
    var body: some View {
        Panel {
            HStack(spacing: 9) {
                if flow.working || flow.state == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: flow.ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(flow.ready ? Palette.green : Palette.amber)
                }
                Text(flow.statusTitle(model)).font(.headline)
            }
            Text(instructions).font(.callout).foregroundStyle(.secondary)
            switch flow.state {
            case .waitingForSteam:
                Button(model.tr("退出 Steam 并继续", "Quit Steam and continue")) { model.quitSteamForPreparation() }
            case .needsRosetta:
                Link(model.tr("阅读 Apple 软件许可", "Read the Apple software license"), destination: URL(string: "https://www.apple.com/legal/sla/")!)
                Toggle(model.tr("我已阅读并同意 Apple 的 Rosetta 2 许可", "I have read and accept Apple's Rosetta 2 license"), isOn: $consent)
                Button(model.tr("授权并继续", "Authorize and continue")) { Task { await flow.grantRosettaConsent() } }
                    .disabled(!consent || model.busy)
            case .failed(let error):
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(model.tr("重试", "Retry")) { model.reconcileRuntimePreparation(retry: true) }.disabled(model.busy)
            case .ready where flow.ready:
                Button(model.tr("打开 Steam", "Open Steam")) { model.launchSteam() }.disabled(model.busy)
            default: EmptyView()
            }
            if (flow.working || flow.state == .needsRosetta) && !flow.detail.isEmpty {
                Text(flow.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .buttonStyle(.borderedProminent)
        .onChange(of: flow.state) { _, state in if state != .needsRosetta { consent = false } }
    }

    private var instructions: String {
        switch flow.state {
        case .checking, .preparing:
            model.tr("保持联网，MacSteamTool 会检查本机的 Steam 并自动准备所需文件。", "Stay connected to the internet while MacSteamTool checks your Steam installation and prepares the files it needs.")
        case .installing:
            model.tr("请保持应用打开。安装完成后，左下角会自动显示联机状态。", "Keep MacSteamTool open. When setup finishes, the bottom of the sidebar will show your multiplayer status.")
        case .waitingForSteam:
            model.tr("先保存游戏并关闭游戏，再点下方按钮退出 Steam。安装会自动继续。", "Save and close your game, then use the button below to quit Steam. Setup will resume automatically.")
        case .needsRosetta:
            model.tr("这台 Mac 需要 Rosetta 2 来运行 Intel 组件。阅读许可后，点「授权并继续」，按 macOS 提示完成安装。", "This Mac needs Rosetta 2 to run Intel components. Read the license, choose Authorize and continue, then follow the macOS prompts.")
        case .failed:
            model.tr("请查看下方原因，处理后点「重试」继续安装。", "Review the issue below, then choose Retry to continue setup.")
        case .ready:
            flow.ready ? model.tr("打开 Steam 并登录你的账号，就可以从游戏库选择游戏，或和好友联机。", "Open Steam and sign in to choose a game from your library or play with friends.") :
                model.tr("正在检查你的兼容层选择，稍后会显示安装进度。", "MacSteamTool is checking your backend choice. Setup progress will appear here.")
        }
    }
}
