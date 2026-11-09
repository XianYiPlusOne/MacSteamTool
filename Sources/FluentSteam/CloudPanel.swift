import SwiftUI
import AppKit
import FluentCore

struct CloudPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<CloudConfiguration> private var config = .init()
    @ViewState<[String: String]> private var credentials = [:]
    @ViewState<CloudProvider> private var source = .local
    @ViewState<CloudProvider> private var destination = .folder
    @ViewState<String> private var status = ""
    @ViewState<Bool> private var confirmMigration = false
    @ViewState<Bool> private var confirmActivation = false
    @ViewState<String> private var runtimeStatus = ""
    @ViewState<String> private var migrationAccount = ""
    private var engine: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Cloud/FluentCloudCLI") }
    private func field(_ name: String, _ key: String, secret: Bool = false) -> some View {
        let binding = Binding(get: { credentials[key] ?? "" }, set: { credentials[key] = $0 })
        return HStack { Text(name).frame(width: 125, alignment: .leading); if secret { SecureField(name, text: binding) } else { TextField(name, text: binding) } }.textFieldStyle(.roundedBorder)
    }
    var body: some View {
        Panel {
            HStack { Label(model.tr("云存档重定向", "Cloud save redirection"), systemImage: "icloud").font(.headline); Spacer(); Button(model.tr("打开云缓存", "Open cloud cache")) { model.openFolder(model.paths.data.appendingPathComponent("CloudRedirect")) } }
            Text(model.tr("默认接管到独立本地文件夹。更改或重置文件夹后保存，会先复制并校验旧目录内容，成功后切换；原目录保留，同名不同内容不会覆盖。保存前请退出 Steam。跨设备请配置云服务或同步文件夹。", "Managed saves use a separate folder. Changing or resetting it copies and verifies existing data before switching; the original is retained and conflicts are not overwritten. Quit Steam before saving. Configure a cloud provider or synced folder for cross-device use.")).font(.caption).foregroundStyle(.secondary)
            Button(model.tr("使用原版式本地配置（待保存）", "Use upstream-style local defaults (save to apply)")) {
                let defaults = CloudConfiguration.localDefaults(paths: model.paths)
                config.enabled = true; config.automaticApps = true; config.provider = defaults.provider; config.folder = defaults.folder
                status = model.tr("已准备本地接管；成就和时长开关未改变。保存时先扫描、备份并校验现有存档。", "Local redirection prepared; achievement/playtime settings unchanged. Saving first scans, backs up and verifies existing saves.")
            }
            Toggle(model.tr("启用存档接管", "Enable save redirection"), isOn: $config.enabled)
            Toggle(model.tr("自动跟随 macSteam 已启用的主游戏（不含 DLC）", "Follow enabled macSteam base games automatically (excluding DLC)"), isOn: $config.automaticApps)
            if config.automaticApps {
                TextField(model.tr("不接管的 AppID（可选，逗号分隔）", "Excluded AppIDs (optional, comma-separated)"), text: $config.excludedApps).textFieldStyle(.roundedBorder)
            } else {
                TextField(model.tr("要接管的 AppID，逗号分隔", "AppIDs to redirect, separated by commas"), text: $config.apps).textFieldStyle(.roundedBorder)
            }
            if !runtimeStatus.isEmpty { Text(runtimeStatus).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
            Divider()
            Text(model.tr("成就、统计与游戏时长", "Achievements, statistics and playtime")).font(.subheadline.bold())
            TextField(model.tr("统计 AppID（独立于存档列表，逗号分隔）", "Statistics AppIDs (separate from saves, comma-separated)"), text: $config.statsApps).textFieldStyle(.roundedBorder)
            Toggle(model.tr("同步成就与统计", "Sync achievements and statistics"), isOn: $config.syncAchievements)
            Toggle(model.tr("记录并同步游戏时长", "Track and sync playtime"), isOn: $config.syncPlaytime)
            Text(model.tr("只处理统计列表中的游戏；不需要开启存档重定向。更改开关后需重启 Steam。", "Only games in the statistics list are included. Save redirection can remain off. Restart Steam after changing these switches.")).font(.caption).foregroundStyle(.secondary)
            if [.folder, .webdav, .s3, .r2].contains(config.provider) {
                Text(model.tr("这些服务商的统计上传会校验远端版本，发生同时写入时重新合并。服务器缺少可靠的版本标记或持续冲突时，保留本地待传数据，稍后重试。", "Statistics uploads check the remote version and re-merge concurrent changes. If reliable version tags are unavailable or conflicts persist, local pending progress is retained for retry.")).font(.caption).foregroundStyle(.secondary)
            }
            if [.gdrive, .onedrive].contains(config.provider) {
                Text(model.tr("统计通过独立快照合并各设备进度；发布并校验完整快照后才清理旧记录。列举不完整或上传失败时保留本地待传数据。", "Statistics merge device progress through separate snapshots. Old records are compacted only after a complete snapshot is published and verified. Incomplete listings or failed uploads keep local progress pending.")).font(.caption).foregroundStyle(.secondary)
            }
            if !config.automaticApps && !config.apps.isEmpty {
                Text(model.tr("管理中的存档 AppID：", "Managed save AppIDs: ") + config.apps).font(.caption).foregroundStyle(.secondary)
            }
            Button(model.tr("恢复默认配置（保存后生效）", "Reset settings to defaults (save to apply)")) { config = .init(); status = model.tr("已重置表单；存档文件和服务商凭证保留。", "Form reset; save files and provider credentials are preserved.") }
            Picker(model.tr("服务商", "Provider"), selection: $config.provider) { ForEach(CloudProvider.allCases) { p in Text(p.title).tag(p) } }.onChange(of: config.provider) { _, _ in credentials = [:] }
            if config.provider == .folder {
                HStack { TextField(model.tr("独立文件夹路径", "Separate folder path"), text: $config.folder).textFieldStyle(.roundedBorder); Button(model.tr("选择…", "Choose…")) { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK, let u = p.url { config.folder = u.path } } }
                Button(model.tr("恢复默认目录（保存时迁移）", "Reset folder to default (migrate on save)")) { config.folder = CloudConfiguration.localDefaults(paths: model.paths).folder }
            }
            if config.provider == .webdav {
                field("URL", "url")
                Picker(model.tr("认证方式", "Authentication"), selection: Binding(get: { credentials["auth"] ?? "basic" }, set: { credentials["auth"] = $0 })) {
                    Text("Basic").tag("basic"); Text("Digest").tag("digest"); Text(model.tr("自动协商", "Automatic negotiation")).tag("auto"); Text("Bearer token").tag("bearer"); Text(model.tr("匿名", "Anonymous")).tag("none")
                }
                if (credentials["auth"] ?? "basic") == "bearer" { field("Bearer token", "bearer_token", secret: true) }
                else if credentials["auth"] != "none" { field(model.tr("用户名", "Username"), "username"); field(model.tr("密码 / 应用密码", "Password / app password"), "password", secret: true) }
                field(model.tr("远端子目录", "Remote subfolder"), "key_prefix")
            }
            if [.s3, .r2].contains(config.provider) {
                field("Endpoint", "endpoint"); if config.provider == .r2 { field("Account ID", "account_id") } else { field("Region", "region") }
                field("Bucket", "bucket"); field("Access Key ID", "access_key_id"); field("Secret Access Key", "secret_access_key", secret: true); field(model.tr("远端子目录", "Remote subfolder"), "key_prefix")
            }
            if [.gdrive, .onedrive].contains(config.provider) {
                field("Refresh token", "refresh_token", secret: true)
                Text(model.tr("可通过浏览器授权，或导入原版 CloudRedirect 的服务商凭证。", "Authorize in your browser or import existing CloudRedirect provider credentials.")).font(.caption).foregroundStyle(Palette.amber)
                Button(model.tr("在浏览器中授权…", "Authorize in browser…")) { authorize() }.disabled(model.busy || model.steamRunning)
                Button(model.tr("导入凭证文件…", "Import credentials…")) { importCredential() }.disabled(model.busy || model.steamRunning)
            }
            if [.webdav, .s3, .r2].contains(config.provider) {
                field(model.tr("自定义 CA 文件（可选）", "Custom CA file (optional)"), "ca_cert_path")
                Toggle(model.tr("允许明文 HTTP（仅可信内网；凭证和存档未加密）", "Allow plaintext HTTP (trusted LAN only; credentials and saves are unencrypted)"), isOn: Binding(get: { credentials["allow_insecure_http"] == "true" }, set: { credentials["allow_insecure_http"] = String($0) })).font(.caption)
            }
            HStack {
                Button(model.tr("备份并保存配置…", "Back up & save configuration…")) { if config.enabled { confirmActivation = true } else { saveConfiguration() } }.disabled(model.steamRunning)
                if ![.local, .folder].contains(config.provider) {
                    Button(model.tr("保存新凭证", "Save new credentials")) { do { guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }; try CloudEngine.saveCredentials(credentials, provider: config.provider, paths: model.paths); credentials = [:]; status = model.tr("凭证已保存为仅当前用户可读的本机文件；尚未切换接管后端，请先测试在线读写。", "Credentials saved in an owner-only local file; active provider unchanged. Test online read/write next.") } catch { model.fail(error) } }.disabled(model.steamRunning || credentials.values.allSatisfy(\.isEmpty))
                }
                Button(model.tr("检查已保存的服务商", "Check saved provider")) { check() }
            }.disabled(model.busy)
            if ![.local, .folder].contains(config.provider) {
                CloudOnlinePanel(provider: config.provider, engine: engine).id(config.provider)
            }
            HStack {
                Button(model.tr("安装 / 更新重定向模块", "Install / update redirect module")) { deploy(remove: false) }
                Button(model.tr("卸载重定向模块", "Uninstall redirect module")) { deploy(remove: true) }
            }.disabled(model.busy || model.steamRunning)
            Text(model.tr("安装与卸载前请退出 Steam；原 Steam.app 会完整备份。当前原生接口已在独立进程验证，尚需完整游戏存档验证。", "Quit Steam before installation or removal. The original Steam.app is backed up. Native interfaces passed isolated process tests; a full game save test is still pending.")).font(.caption).foregroundStyle(Palette.amber)
            Divider().padding(.vertical, 5)
            Text(model.tr("复制云存档到另一个服务商", "Copy saves to another provider")).font(.subheadline.bold())
            TextField(model.tr("只复制指定账号（可选，AccountID 或 SteamID64）", "Restrict copy to an account (optional AccountID or SteamID64)"), text: $migrationAccount).textFieldStyle(.roundedBorder)
            HStack {
                Picker(model.tr("从", "From"), selection: $source) { ForEach(CloudProvider.allCases) { Text($0.title).tag($0) } }
                Image(systemName: "arrow.right")
                Picker(model.tr("到", "To"), selection: $destination) { ForEach(CloudProvider.allCases) { Text($0.title).tag($0) } }
                Button(model.tr("复制并校验…", "Copy & verify…")) { confirmMigration = true }.disabled(model.busy || source == destination || model.steamRunning)
            }
            Text(model.tr("先分别保存源和目标的配置。复制保留源数据，逐文件回读校验；同名但内容不同的目标文件会保留并报告冲突。迁移前请退出 Steam。", "Save both provider configurations first. Source data is retained and copied files are read back for verification. Conflicting destination files are preserved and reported. Quit Steam before migration.")).font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled).padding(.top, 5) }
        }
        .task {
            do { config = try CloudConfiguration.load(paths: model.paths) } catch { model.fail(error) }
            while !Task.isCancelled {
                refreshRuntimeStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .confirmationDialog(model.tr("将只读扫描所选游戏存档，创建并校验独立备份，然后启用接管。不会还原或覆盖游戏存档。自动模式也会接管今后启用的主游戏。", "Scan selected saves read-only, create and verify an independent backup, then enable redirection. Game saves will not be restored or overwritten. Automatic mode also includes future enabled base games."), isPresented: $confirmActivation) {
            Button(model.tr("备份并保存", "Back up & save")) { saveConfiguration() }
        }
        .confirmationDialog(migrationAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model.tr("将复制源服务商中所有账号的云存档，并保留源数据。", "Copy cloud saves for all accounts from this provider, keeping source data?") : model.tr("只复制所填账号的云存档，保留源数据；同名冲突不会覆盖。", "Copy only the specified account; keep source data and do not overwrite conflicts."), isPresented: $confirmMigration) {
            Button(model.tr("复制并校验", "Copy & verify")) {
                model.run(model.tr("迁移云存档", "Migrate cloud saves")) {
                    guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
                    var arguments = ["migrate", source.rawValue, destination.rawValue]
                    if !migrationAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments.append(try CloudOnline.accountID(migrationAccount)) }
                    let text = try await CloudEngine.run(arguments, executable: engine, paths: model.paths, timeout: 1800)
                    let last = text.split(separator: "\n").last.map(String.init) ?? "{}"
                    let j = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any] ?? [:]
                    status = model.tr("已复制 \(j["migrated"] ?? 0) 个，已存在且一致 \(j["skipped"] ?? 0) 个。", "Copied \(j["migrated"] ?? 0); already identical \(j["skipped"] ?? 0).")
                }
            }
        }
    }
    private func authorize() {
        let provider = config.provider
        model.run(model.tr("等待云服务商授权", "Waiting for cloud authorization")) {
            guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
            var request = SteamEngineRequest("cloud-oauth"); request.provider = provider.rawValue
            let result = try await SteamEngine.run(request, executable: model.engineExecutable) { text in
                guard let url = URL(string: text), url.scheme == "https", ["accounts.google.com", "login.microsoftonline.com"].contains(url.host ?? "") else { return }
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            guard let tokens = result.cloudTokens else { throw AppFailure("云服务商未返回凭证 / Cloud provider returned no credentials") }
            guard !SteamProcesses.isRunning else { throw AppFailure("Steam 已启动，未替换云服务商凭证 / Steam started; cloud credentials were not replaced") }
            try CloudEngine.saveCredentials(tokens, provider: provider, paths: model.paths)
            status = model.tr("授权成功，凭证已保存在本机", "Authorized; credentials saved locally")
        }
    }
    private func deploy(remove: Bool) {
        model.run(model.tr("部署云存档模块", "Deploy cloud module"), cancellable: false) {
            let library = engine.deletingLastPathComponent().appendingPathComponent("cloud_redirect.dylib")
            let backup = try await KernelDeployment.deploy(name: "cloud_redirect.dylib", source: remove ? nil : library, paths: model.paths)
            model.needsRestart = true; model.refresh()
            status = model.tr("模块已更新。原应用备份：", "Module updated. Original app backup: ") + backup.path
        }
    }
    private func check() {
        model.run(model.tr("检查云存档配置", "Check cloud configuration")) {
            let saved = try CloudConfiguration.load(paths: model.paths)
            _ = try await CloudEngine.run(["auth-status", saved.provider.rawValue], executable: engine, paths: model.paths)
            status = model.tr("已保存服务商的认证检查通过；表单未保存、存档未上传。完整同步仍需实际游戏验证。", "Saved provider auth check passed; form not saved and no saves uploaded. Full sync still requires a real game test.")
        }
    }
    private func saveConfiguration() {
        let requested = config, paths = model.paths
        model.run(model.tr("备份并配置云存档", "Back up & configure cloud saves"), cancellable: false) {
            guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
            var inventory: CloudSaveInventory?
            if requested.enabled {
                let ids = try requested.selectedApps(paths: paths)
                let text = try await CloudEngine.run(["scan-local-saves", ids.map(String.init).joined(separator: ",")], executable: engine, paths: paths)
                guard let line = text.split(separator: "\n").last else { throw AppFailure("存档扫描未返回结果 / Save scan returned no result") }
                inventory = try JSONDecoder().decode(CloudSaveInventory.self, from: Data(line.utf8))
            }
            let files = inventory
            let backup = try await Task.detached { try CloudActivation.save(requested, inventory: files, paths: paths) }.value
            model.needsRestart = true
            status = model.tr("配置已保存；下次启动 Steam 生效。", "Configuration saved; applies on next Steam launch.")
            if let backup { status += model.tr("\n已校验备份：", "\nVerified backup: ") + backup.path }
            refreshRuntimeStatus()
        }
    }
    private func refreshRuntimeStatus() {
        do {
            let saved = try CloudConfiguration.load(paths: model.paths)
            let ids = try saved.selectedApps(paths: model.paths)
            var lines = [model.tr("已保存：", "Saved: ") + (saved.enabled ? model.tr("接管 \(ids.count) 款游戏", "\(ids.count) managed games") : model.tr("未启用接管", "Redirection disabled"))]
            if saved.enabled { lines.append(saved.provider == .folder ? saved.folder : saved.provider.title) }
            if let runtime = CloudRuntimeStatus.current(paths: model.paths) {
                if runtime.needsRestart(paths: model.paths) { lines.append(model.tr("运行中配置不同或扩展版本过旧：需要重启 / 更新模块", "Running configuration differs or module is outdated: restart / update module")) }
                else if saved.enabled {
                    lines.append(runtime.cloudReady == true ? model.tr("服务商已就绪", "Provider ready") : model.tr("服务商未就绪；接管请求将报告失败", "Provider unavailable; managed requests will fail"))
                    lines.append(model.tr("已加载 \(runtime.cloudAppsLoaded ?? 0) 款；RPC 请求 \(runtime.cloudRequests ?? 0)，失败 \(runtime.cloudFailures ?? 0)（不等于已同步文件数）", "\(runtime.cloudAppsLoaded ?? 0) games loaded; \(runtime.cloudRequests ?? 0) RPC requests, \(runtime.cloudFailures ?? 0) failed (not a synced file count)"))
                }
            } else { lines.append(model.tr("尚未检测到当前 Steam 的扩展状态", "No module status detected for the current Steam process")) }
            runtimeStatus = lines.joined(separator: "\n")
        } catch { runtimeStatus = error.localizedDescription }
    }
    private func importCredential() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let u = panel.url {
            do {
                guard !SteamProcesses.isRunning else { throw AppFailure("请先退出 Steam / Quit Steam first") }
                let j = try JSONSerialization.jsonObject(with: FileStore.read(u)) as? [String: Any] ?? [:]
                guard let refresh = j["refresh_token"] as? String, !refresh.isEmpty else { throw AppFailure("文件中没有 refresh_token / File contains no refresh_token") }
                try CloudEngine.saveCredentials(["refresh_token": refresh], provider: config.provider, paths: model.paths)
                status = model.tr("已导入凭证", "Credentials imported")
            } catch { model.fail(error) }
        }
    }
}
