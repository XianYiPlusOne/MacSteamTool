import SwiftUI
import AppKit
import FluentCore

struct RuntimeActions: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var macSteam = "/Applications/macSteam Config.app"
    @ViewState<String> private var notProton = "/Applications/NotProton.app"
    @ViewState<String> private var crossOver = ""
    @ViewState<[RuntimeBackup]> private var backups = []
    @ViewState<RuntimeBackup?> private var restore = nil
    @ViewState<Bool> private var confirmCleanup = false
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.tr("安装与恢复", "Install & restore")).font(.headline)
                Text(model.tr("从本机官方管理器读取内核资源，在此安装或更新。操作前备份 Steam 和受影响的运行器；新建运行器需有效的 CrossOver 授权。", "Install or update using resources from the official local companion apps. Steam and affected runtime files are backed up first. A valid CrossOver license is required for a new runner.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("macSteam").frame(width: 90, alignment: .leading)
                    TextField("macSteam Config.app", text: $macSteam)
                    Button(model.tr("选择…", "Choose…")) { choose(&macSteam) }
                    Button(model.tr("安装 / 更新", "Install / update")) { install(kernel: "macsteam.dylib", companion: macSteam) }.disabled(model.steamRunning || model.busy)
                    Button(model.tr("卸载内核", "Remove kernel")) { install(kernel: "macsteam.dylib", remove: true) }.disabled(model.steamRunning || model.busy)
                }
                HStack {
                    Text("NotProton").frame(width: 90, alignment: .leading)
                    TextField("NotProton.app", text: $notProton)
                    Button(model.tr("选择…", "Choose…")) { choose(&notProton) }
                    Button(model.tr("安装 / 更新", "Install / update")) { install(companion: notProton) }.disabled(model.steamRunning || model.busy)
                    Button(model.tr("卸载内核", "Remove kernel")) { install(kernel: "notproton.dylib", remove: true) }.disabled(model.steamRunning || model.busy)
                }
                Button(model.tr("卸载 NotProton 并清理运行器…", "Remove NotProton and clean runners…")) { confirmCleanup = true }.disabled(model.steamRunning || model.busy)
                HStack {
                    Button(model.tr("修复 NotProton 日志入口", "Repair NotProton log action")) { install(kernel: "notproton.dylib") }.disabled(model.steamRunning || model.busy)
                    Text(model.tr("适用于已安装的 1.2.3；备份后安装 Fluent 修复版。", "For installed 1.2.3; backs up Steam and installs the Fluent repair.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("CrossOver").frame(width: 90, alignment: .leading)
                    TextField(model.tr("可选：选择 CrossOver.app 以添加运行器", "Optional: choose CrossOver.app to add a runner"), text: $crossOver)
                    Button(model.tr("选择…", "Choose…")) { choose(&crossOver) }
                    if !crossOver.isEmpty { Button(model.tr("清除", "Clear")) { crossOver = "" } }
                }
                Divider()
                Toggle(model.tr("启动时检查内核更新", "Check runtime updates at launch"), isOn: Binding(get: { model.preferences.automaticallyCheckRuntimeUpdates == true }, set: { model.preferences.automaticallyCheckRuntimeUpdates = $0; model.savePreferences() }))
                if !model.runtimeUpdateStatus.isEmpty { Text(model.runtimeUpdateStatus).font(.caption).foregroundStyle(.secondary) }
                RuntimeUpdatePanel(provider: "macsteam", companion: $macSteam)
                RuntimeUpdatePanel(provider: "notproton", companion: $notProton)
                Text(model.tr("下载会校验官方摘要、应用签名与内核资源；安装仍会先备份。", "Downloads verify the official digest, app signatures and kernel resources. Installation creates a backup first.")).font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Fluent Manifest").font(.subheadline.bold())
                    Spacer()
                    Button(model.tr("同步已有 Lua 锁定与令牌", "Sync existing Lua pins and tokens")) {
                        model.run(model.tr("同步版本锁定", "Sync version pins")) { try model.service.synchronizeManifestPins(); model.refresh() }
                    }.disabled(model.busy)
                    Button(model.tr("安装 / 更新扩展", "Install / update extension")) {
                        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Manifest/fluent_manifest.dylib")
                        model.run(model.tr("安装 Manifest 扩展", "Install manifest extension"), cancellable: false) {
                            _ = try await KernelDeployment.deploy(name: "fluent_manifest.dylib", source: source, paths: model.paths)
                            model.needsRestart = true; model.refresh(); reload()
                        }
                    }.disabled(model.steamRunning || model.busy)
                    Button(model.tr("卸载扩展", "Remove extension")) { install(kernel: "fluent_manifest.dylib", remove: true) }.disabled(model.steamRunning || model.busy)
                }
                Text(model.tr("使启用游戏的 setManifestid 在 public 分支生效；对应 Manifest 必须已缓存并校验。当前支持 ARM64 Steam build 1792618285，其他版本自动透传。安装后需重启 Steam。", "Applies enabled games' setManifestid pins to the public branch when the matching manifest is cached and verified. Supports ARM64 Steam build 1792618285; other builds pass through. Restart Steam after installation.")).font(.caption).foregroundStyle(.secondary)
                Text(model.runtime.manifestPinsLoaded.isEmpty ? model.tr("当前 Steam 进程尚未加载此扩展", "This extension is not loaded in the current Steam process") : model.runtime.manifestPinsLoaded).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.tr("卸载内核会移除 Steam 加载项，保留游戏、前缀和运行器。安装过程中请保持 Steam 关闭，签名和恢复完成前不能中止。", "Removing a kernel detaches it from Steam and keeps games, prefixes and runners. Keep Steam closed until installation and recovery finish.")).font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text(model.tr("可恢复的安装备份", "Installation backups")).font(.subheadline.bold())
                    Spacer()
                    Button(model.tr("刷新", "Refresh")) { reload() }
                    Button(model.tr("打开目录", "Open folder")) { model.openFolder(model.paths.data.appendingPathComponent("RuntimeBackups")) }
                }
                if backups.isEmpty { Text(model.tr("安装后将在此列出完整备份。", "Full backups appear here after an installation.")).font(.caption).foregroundStyle(.secondary) }
                ForEach(backups.prefix(8)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.isNotProton ? "NotProton" : model.tr("Steam 内核", "Steam kernel")).font(.caption.bold())
                            Text(item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            if item.interrupted { Text(model.tr("安装中断 · 可备份当前状态后恢复", "Interrupted · current state will be backed up before recovery")).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button(model.tr("恢复…", "Restore…")) { restore = item }.disabled(model.busy || model.steamRunning)
                    }
                }
            }
        }
        .task { reload() }
        .confirmationDialog(model.tr("先备份，再移除 NotProton 内核、运行器和桥接文件？游戏目录、各游戏前缀与存档保留。可以从安装备份恢复。", "Back up, then remove the NotProton kernel, runners and bridge files? Game folders, per-game prefixes and saves are preserved. Installation backups allow restoration."), isPresented: $confirmCleanup) {
            Button(model.tr("备份并卸载", "Back up and remove")) { perform(kernel: "notproton.dylib", remove: true, cleanRunners: true) }
        }
        .confirmationDialog(restore?.interrupted == true ? model.tr("恢复中断的安装？将先完整备份当前状态，再还原所选备份；游戏和前缀不会被更改。", "Recover interrupted installation? The current state is backed up in full first. Games and prefixes are not changed.") : model.tr("恢复此备份？若安装后文件已发生变化，将停止恢复。", "Restore this backup? Recovery stops if installed files have changed since then."), isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } })) {
            if let item = restore {
                Button(model.tr("恢复备份", "Restore backup")) { perform(restoring: item); restore = nil }
            }
        }
    }
    private func choose(_ value: inout String) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
    private func reload() { backups = RuntimeInstaller.backups(model.paths) }
    private func install(kernel: String? = nil, companion: String? = nil, remove: Bool = false) {
        perform(kernel: kernel, companion: companion, remove: remove)
    }
    private func perform(kernel: String? = nil, companion: String? = nil, remove: Bool = false, cleanRunners: Bool = false, restoring: RuntimeBackup? = nil) {
        let paths = model.paths, source = companion.map { URL(fileURLWithPath: $0) }, runner = crossOver.isEmpty ? nil : URL(fileURLWithPath: crossOver)
        model.run(model.tr("部署 / 恢复内核", "Deploy / restore runtime"), cancellable: false) {
            defer { reload() }
            let backup = try await RuntimeInstaller.run(paths: paths, kernel: kernel, companion: source, crossOver: runner, remove: remove, cleanRunners: cleanRunners, restoring: restoring) { text in
                await MainActor.run { model.progress = text }
            }
            model.log(model.tr("安装备份：", "Installation backup: ") + backup.path)
            model.needsRestart = true; model.refresh(); reload()
        }
    }
}
