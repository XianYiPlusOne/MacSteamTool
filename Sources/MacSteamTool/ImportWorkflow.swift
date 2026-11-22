import SwiftUI
import MacSteamToolCore

struct LibraryImportActivity {
    var appID: Int
    var title: String
    var logs: [String] = []
    var content: [LibraryContentReport] = []
    var finished = false
    var failed = false
    var cancelled = false
}

extension AppModel {
    func refreshSteamAfterImport(appID: Int?, clientRunning: Bool? = nil, navigate: ((String) -> Void)? = nil) async {
        func show(_ url: String) {
            if let navigate { navigate(url) }
            else if !testing { openSteamClientURL(url) }
        }
        guard clientRunning ?? steamRunning else {
            log(tr("已入库，下次启动 Steam 时加载。", "Added; Steam will load it on next launch."))
            return
        }
        show(appID.map { "steam://nav/games/details/\($0)" } ?? "steam://nav/games")
        log(tr("已入库，已请求 Steam 显示游戏库。授权、安装及下载状态由 Steam 管理。", "Added. Requested the Steam library view. Steam manages ownership, installation and downloads."))

    }

    var importWorkflowPresented: Bool { importActivity != nil || pendingImport != nil }
    func recordImportProgress(_ text: String) {
        progress = text
        importActivity?.title = text
        importActivity?.logs.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
        log(text)
    }
    func finishImportProgress(_ text: String, failed: Bool = false, cancelled: Bool = false) {
        guard importActivity != nil else { return }
        recordImportProgress(text)
        importActivity?.finished = true
        importActivity?.failed = failed
        importActivity?.cancelled = cancelled
    }
    func closeImportWorkflow() {
        guard !busy else { return }
        if pendingImport != nil { cancelImport() }
        importActivity = nil
        message = nil
    }
}

struct ImportWorkflowSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let session = model.pendingImport {
                ImportPreview(session: session)
            } else if let activity = model.importActivity {
                VStack(alignment: .leading, spacing: 18) {
                    SheetHeader(canClose: !model.busy && activity.finished, onClose: model.closeImportWorkflow) {
                        if !activity.finished { ProgressView().controlSize(.large) }
                        else { Image(systemName: activity.cancelled ? "xmark.circle" : activity.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.largeTitle).foregroundStyle(activity.cancelled ? Color.secondary : activity.failed ? Palette.amber : Palette.green) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(activity.finished ? model.tr("入库检查结果", "Import check result") : model.tr("正在检查并准备入库", "Checking and preparing import")).font(.title2.bold())
                            Text("AppID \(String(activity.appID))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(activity.title).font(.headline).lineLimit(3).help(activity.title).textSelection(.enabled)
                    if !activity.finished { Text(model.tr("正在核对游戏、DLC 与内容仓库，缺项时会继续尝试补齐来源。", "Checking the game, DLC and depots; missing content triggers fallback sources.")).font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ImportContentList(items: activity.content)
                            ImportCheckLog(lines: activity.logs, live: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        if !activity.finished {
                            Button(model.tr("取消检查", "Cancel check")) { model.cancel() }.disabled(!model.canCancelOperation)
                        }
                        Spacer()
                        if activity.finished { Button(model.tr("完成", "Done")) { model.closeImportWorkflow() }.buttonStyle(.borderedProminent).disabled(model.busy) }
                    }
                }.padding(26).frame(width: 820, height: 680)
            }
        }.interactiveDismissDisabled(true)
    }
}

struct ImportContentList: View {
    @EnvironmentObject var model: AppModel
    let items: [LibraryContentReport]
    var body: some View {
        if !items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(model.tr("内容检查明细", "Content check details")).font(.headline)
                ForEach(items) { item in
                    Panel(padding: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text("\(item.isMain ? model.tr("主游戏", "Main game") : "DLC") · AppID \(String(item.id))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text((!item.metadataKnown || !item.issues.isEmpty) ? model.tr("资料待核实", "Metadata unverified") : !item.missingDepots.isEmpty ? model.tr("缺少密钥", "Missing keys") : model.tr("范围内密钥齐全", "Scoped keys complete"))
                                .font(.caption.bold()).foregroundStyle(!item.metadataKnown || !item.issues.isEmpty || !item.missingDepots.isEmpty ? Palette.amber : Palette.green)
                        }
                        if item.depots.isEmpty {
                            Text(model.tr("当前范围没有独立 Depot；内容完整性以提示为准。", "No separate depot in this scope; review the content notes.")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(item.issues, id: \.self) { issue in
                            Text(issue).font(.caption).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(item.depots) { depot in
                            HStack(alignment: .top) {
                                Image(systemName: depot.hasKey ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(depot.hasKey ? Palette.green : Palette.amber)
                                Text("Depot \(String(depot.id))").font(.system(.caption, design: .monospaced))
                                Text([depot.platform, depot.language ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(depot.hasKey ? model.tr("密钥已找到", "Key found") : model.tr("缺少密钥", "Missing key")).font(.caption).foregroundStyle(depot.hasKey ? Palette.green : Palette.amber)
                            }
                        }
                    }.textSelection(.enabled)
                }
            }
        }
    }
}

struct ImportCheckLog: View {
    @EnvironmentObject var model: AppModel
    let lines: [String]
    var live = false
    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(model.tr("完整检查日志", "Full check log"), systemImage: "list.bullet.rectangle").font(.headline)
                    Spacer()
                    Button(model.tr("复制日志", "Copy log")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) }.font(.caption)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(lines.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("logEnd")
                        }.padding(12)
                    }.frame(height: live ? 220 : 260).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: lines.count) { _, _ in if live { proxy.scrollTo("logEnd", anchor: .bottom) } }
                }
            }
        }
    }
}
