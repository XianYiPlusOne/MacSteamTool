import SwiftUI
import AppKit
import MacSteamToolCore

struct GettingStartedPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var flow: RuntimePreparationController
    @ViewState<GuideEnvironment?> private var environment = nil
    @ViewState<Int> private var revision = 0
    @ViewState<Bool> private var consent = false
    @ViewState<Bool> private var revisingChoice = false

    private var step: GuideStep {
        if revisingChoice, environment?.steam != nil {
            switch flow.state {
            case .ready, .wineNotInstalled, .failed: return .choice
            default: break
            }
        }
        return GuideStep(environment: environment, runtime: flow.state, hasPendingChoice: flow.pendingBackend != nil, installer: model.guideSteamInstallation)
    }
    private var position: Int {
        if step == .complete { return 2 }
        return environment?.steam == nil ? 0 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
                    .accessibilityHidden(true)
                Text(model.tr("设置你的游戏库", "Set up your game library"))
                    .font(.system(size: 29, weight: .bold)).accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 12) {
                milestone(0, "Steam")
                connector
                milestone(1, model.tr("Windows 游戏", "Windows games"))
                connector
                milestone(2, model.tr("完成", "Finish"))
            }
            VStack(alignment: .leading, spacing: 18) {
                currentStep
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.09)))
            if let steam = environment?.steam {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.tr("已找到 Steam", "Steam detected")).font(.callout.weight(.medium))
                        Text(verbatim: steam.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).accessibilityLabel(model.tr("重新检测 Steam 和兼容层", "Check Steam and game runners again"))
                        .help(model.tr("重新检测 Steam 和兼容层", "Check Steam and game runners again"))
                }.padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: 670).frame(maxWidth: .infinity).padding(.vertical, 20)
        .onAppear { model.markGuideSeen() }
        .task(id: revision) {
            let isolated = model.testing, paths = isolated ? model.defaults : model.paths
            let home = model.home, preview = model.previewCrossOver, installed = model.guideSteamInstallation.installedApp
            let snapshot = await Task.detached(priority: .utility) { GuideEnvironment.read(paths: paths, isolated: isolated, previewCrossOver: preview, installedSteam: installed, home: home) }.value
            if !Task.isCancelled { environment = snapshot }
        }
        .onChange(of: model.guideSteamInstallation) { _, state in
            if state.installedApp != nil { environment = nil; revision += 1 }
        }
        .onChange(of: model.previewCrossOver) { _, _ in revision += 1 }
        .onChange(of: model.paths.steamApp) { _, _ in revision += 1 }
        .onChange(of: scenePhase) { _, phase in if phase == .active { revision += 1 } }
        .onChange(of: flow.state) { _, state in
            if state != .needsRosetta { consent = false }
            if state == .ready || state == .wineNotInstalled { revision += 1 }
        }
    }

    private var connector: some View {
        Rectangle().fill(.secondary.opacity(0.24)).frame(maxWidth: .infinity).frame(height: 1).accessibilityHidden(true)
    }

    private func milestone(_ index: Int, _ name: String) -> some View {
        let done = index < position || step == .complete
        return HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : index == position ? "circle.inset.filled" : "circle")
            Text(name).font(.callout.weight(index == position ? .semibold : .regular)).fixedSize()
        }.foregroundStyle(index <= position ? Palette.accent : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? model.tr("已完成", "Completed") : index == position ? model.tr("当前步骤", "Current step") : "")
    }

    @ViewBuilder private var currentStep: some View {
        switch step {
        case .checking:
            heading(model.tr("正在检查这台 Mac", "Checking this Mac"))
            ProgressView().controlSize(.small)
        case .steam:
            heading(model.tr("先安装 Steam", "Install Steam to get started"))
            description(model.tr("从 Valve 下载官方客户端。安装完成后，你可以选择 Wine 或 CrossOver。", "Download the official client from Valve. Once installed, choose Wine or CrossOver."))
            installSteamButton(retry: false)
        case .downloadingSteam, .installingSteam:
            heading(step == .downloadingSteam ? model.tr("正在下载并验证 Steam", "Downloading and verifying Steam") : model.tr("正在安装 Steam", "Installing Steam"))
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(verbatim: model.guideSteamDestination.path).font(.callout).foregroundStyle(.secondary)
            }
        case .steamFailure(let reason):
            heading(model.tr("Steam 安装未完成", "Steam installation did not finish"))
            Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            installSteamButton(retry: true)
        case .choice:
            heading(model.tr("选择 Windows 游戏的运行方式", "Choose how to run Windows games"))
            if let wine = environment?.detectedWine {
                backendOption("Wine", detail: model.tr("已检测到本机 Wine，可直接使用。需要 Steam 桥接的游戏可选择下方的 MacSteamTool Wine。", "Local Wine is available. For games that need Steam integration, choose MacSteamTool Wine below."), path: wine,
                              action: model.tr("使用本机 Wine", "Use local Wine")) { choose(.localWine(wine)) }
                Button(environment?.wineInstalled == true ? model.tr("使用 MacSteamTool Wine", "Use MacSteamTool Wine") : model.tr("安装带 Steam 桥接的 Wine", "Install Wine with the Steam bridge")) { choose(.wine) }
                    .buttonStyle(.link).disabled(model.busy)
            } else {
                backendOption("Wine", detail: environment?.wineInstalled == true
                    ? model.tr("已检测到 MacSteamTool Wine，可以直接使用。", "MacSteamTool Wine was found and is ready to use.")
                    : model.tr("免费。首次使用会下载运行器和图形组件。", "Free. Downloads the runner and graphics components on first use."),
                    action: environment?.wineInstalled == true ? model.tr("使用现有 Wine", "Use existing Wine") : model.tr("安装 Wine", "Install Wine")) { choose(.wine) }
            }
            Divider()
            if let app = environment?.detectedCrossOver {
                backendOption("CrossOver", detail: model.tr("已检测到 CrossOver，可使用已激活的应用。", "CrossOver was found on this Mac. Use your activated copy."), path: app,
                              action: model.tr("使用现有 CrossOver", "Use existing CrossOver")) { choose(.crossOver(app)) }
            } else {
                backendOption("CrossOver", detail: model.tr("使用你已购买并激活的应用。", "Use your purchased and activated app."),
                              action: model.tr("选择 CrossOver…", "Choose CrossOver…")) { chooseCrossOver() }
            }
            if environment?.detectedCrossOver != nil {
                Button(model.tr("选择其他 CrossOver 应用…", "Choose a different CrossOver app…")) { chooseCrossOver() }
                    .buttonStyle(.link).disabled(model.busy)
            }
            Divider()
            Button(model.tr("仅管理本机游戏", "Manage local games only")) { model.page = .library }.buttonStyle(.link)
        case .working:
            heading(flow.pendingBackend == .wine ? model.tr("正在准备 Wine", "Setting up Wine") : model.tr("正在准备游戏环境", "Preparing your game environment"))
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                description(flow.detail.isEmpty ? model.tr("请保持 MacSteamTool 打开。", "Keep MacSteamTool open.") : flow.detail)
            }
        case .quitSteam:
            heading(model.tr("先保存游戏并退出 Steam", "Save your game and quit Steam"))
            description(model.tr("退出后会从这里自动继续。", "Setup will resume here when Steam quits."))
            Button(model.tr("退出 Steam 并继续", "Quit Steam and continue")) { model.quitSteamForPreparation() }.buttonStyle(.borderedProminent)
        case .rosetta:
            heading(model.tr("允许安装 Rosetta 2", "Allow Rosetta 2 installation"))
            description(model.tr("这台 Mac 需要 Rosetta 2 才能运行 Intel 组件。", "This Mac needs Rosetta 2 to run Intel components."))
            Link(model.tr("阅读 Apple 软件许可", "Read the Apple software license"), destination: URL(string: "https://www.apple.com/legal/sla/")!)
            Toggle(model.tr("我已阅读并同意 Rosetta 2 许可", "I have read and accept the Rosetta 2 license"), isOn: $consent)
            if !flow.detail.isEmpty { description(flow.detail) }
            Button(model.tr("授权并继续", "Authorize and continue")) { Task { await flow.grantRosettaConsent() } }
                .buttonStyle(.borderedProminent).disabled(!consent || model.busy)
        case .failure(let reason):
            heading(model.tr("设置遇到了问题", "Setup needs attention"))
            Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(model.tr("重试这一步", "Retry this step")) { model.reconcileRuntimePreparation(retry: true) }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                if flow.pendingBackend != nil, environment?.steam != nil {
                    Button(model.tr("重新选择", "Change choice")) { revisingChoice = true }
                } else {
                    Button(model.tr("进入游戏库", "Go to library")) { model.page = .library }
                }
            }
            if environment?.steam == nil {
                installSteamButton(retry: false)
            }
        case .complete:
            heading(model.testing && model.previewCrossOver != nil ? model.tr("CrossOver 检查完成", "CrossOver check complete") : model.tr("你的游戏库已准备好", "Your game library is ready"))
            if environment?.usingLocalWine == true, let wine = environment?.detectedWine {
                Label(model.tr("本机 Wine 已就绪", "Local Wine is ready"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                Text(verbatim: wine.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let backend = environment?.activeBackend {
                Label(model.testing && model.previewCrossOver != nil ? model.tr("已验证 CrossOver 应用", "CrossOver app verified") : model.tr("\(backend) 已就绪", "\(backend) is ready"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.green)
            }
            description(model.testing && model.previewCrossOver != nil ? model.tr("本次预览已确认运行器的位置。正式配置可在普通模式中完成。", "This preview confirmed the runner’s location. Complete configuration in a regular session.") : model.tr("打开游戏库，查看这台 Mac 上的游戏和安装状态。", "Open your library to see the games on this Mac and their install status."))
            HStack(spacing: 14) {
                Button(model.tr("进入游戏库", "Open game library")) { model.page = .library }.buttonStyle(.borderedProminent)
                Button(model.tr("更换兼容层", "Change compatibility layer")) { revisingChoice = true }
            }.controlSize(.large)
        }
    }

    private func installSteamButton(retry: Bool) -> some View {
        Button(retry ? model.tr("重试安装 Steam", "Retry Steam installation") : model.tr("下载并安装 Steam", "Download and install Steam")) {
            Task { await model.installSteamFromGuide() }
        }.buttonStyle(.borderedProminent).disabled(model.busy || model.guideSteamInstallation.isRunning)
    }

    private func backendOption(_ name: String, detail: String, path: URL? = nil, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let path {
                    Text(verbatim: path.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(path.path).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button(action, action: perform).disabled(model.busy)
        }
    }

    private func choose(_ backend: RuntimePreparationController.Backend) {
        revisingChoice = false
        model.chooseTranslationBackend(backend)
    }
    private func heading(_ text: String) -> some View {
        Text(text).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
    private func description(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func chooseCrossOver() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            choose(.crossOver(url))
        }
    }
}
