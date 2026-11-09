import SwiftUI
import FluentCore
import CoreImage.CIFilterBuiltins

extension AppModel {
    var engineExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/SteamEngine/FluentSteamEngine") }
    func exportTickets(_ id: Int) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = tr("导出票据", "Export tickets")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        run(tr("提取 Steam 票据", "Extract Steam tickets")) {
            guard !self.testing, self.steamRunning else { throw AppFailure("请先登录并运行原生 Steam / Sign in and run native Steam first") }
            var request = AchievementRequest(appID: id, library: self.paths.steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib").path)
            request.operation = "tickets"
            let result = try await AchievementWorker.run(request, executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FluentSteamWorker"))
            guard let ownership = result.ownershipTicket, let encrypted = result.encryptedTicket else { throw AppFailure("Steam 没有返回完整票据 / Steam did not return complete tickets") }
            let output = folder.appendingPathComponent("Tickets-\(id)-\(UUID().uuidString.prefix(8))")
            try FileStore.fm.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, data) in [("\(id).appticket", ownership), ("\(id).eticket", encrypted)] {
                let file = output.appendingPathComponent(name); try FileStore.write(data, to: file)
                try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            self.openFolder(output)
        }
    }
    func onlineLogin() {
        run(tr("等待 Steam Guard 扫码", "Waiting for Steam Guard")) {
            self.loginQR = ""; defer { self.loginQR = "" }
            let state = self
            let result = try await SteamEngine.run(SteamEngineRequest("login"), executable: self.engineExecutable, status: { url in
                await state.setLoginQR(url)
            })
            try self.completeOnlineAuthentication(result)
            self.log(self.tr("SteamKit 登录成功，凭证已保存在钥匙串", "SteamKit signed in; credential saved in Keychain"))
        }
    }
    func onlinePasswordLogin(account: String, password: String) {
        var request = SteamEngineRequest("login-password"); request.account = account; request.password = password
        authenticate(request)
    }
    func onlineLocalLogin(_ account: SteamAccount) {
        var request = SteamEngineRequest("login-local"); request.account = account.name; request.steamID = account.id; request.steamPath = paths.steam.path
        authenticate(request)
    }
    private func authenticate(_ request: SteamEngineRequest) {
        run(tr("登录 SteamKit", "Sign in to SteamKit")) {
            guard !self.testing else { throw AppFailure("隔离环境不连接真实账号 / Fixture does not connect to real accounts") }
            let result = try await SteamEngine.run(request, executable: self.engineExecutable, challenge: { prompt in
                await MainActor.run {
                    let alert = NSAlert(); alert.messageText = prompt
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 24)); alert.accessoryView = field
                    alert.addButton(withTitle: "提交 / Submit"); alert.addButton(withTitle: "取消 / Cancel")
                    alert.window.initialFirstResponder = field
                    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
                }
            })
            try self.completeOnlineAuthentication(result)
        }
    }
    func completeOnlineAuthentication(_ result: SteamEngineResponse, persist: (SteamCredential) throws -> Void = SteamKeychain.save) throws {
        guard let account = result.account, !account.isEmpty, let token = result.token, !token.isEmpty else { throw AppFailure("Steam 未返回完整凭证 / Steam returned incomplete credentials") }
        try persist(SteamCredential(account: account, token: token))
        ownedGames = []; onlineAccount = account
    }
    private func setLoginQR(_ url: String) { loginQR = url }
    func onlineLibrary() {
        run(tr("读取账号已拥有的游戏", "Read owned games")) {
            guard let credential = try SteamKeychain.load() else { throw AppFailure("请先使用 Steam Guard 登录 / Sign in with Steam Guard first") }
            let result = try await SteamEngine.run(SteamEngineRequest("library", credential: credential), executable: self.engineExecutable)
            self.onlineAccount = credential.account; self.ownedGames = (result.games ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    func onlineExtract(_ ids: [Int], manifests: Bool, includeDLC: Bool, schema: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = tr("导出到此目录", "Export here")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run(tr("提取正版 Lua / 密钥", "Extract owned Lua / keys")) {
            guard let credential = try SteamKeychain.load() else { throw AppFailure("请先使用 Steam Guard 登录 / Sign in with Steam Guard first") }
            let export = destination.appendingPathComponent("Steam-Export-\(UUID().uuidString.prefix(8))")
            try FileStore.fm.createDirectory(at: export, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var errors: [String] = []
            for (index, id) in ids.enumerated() {
                try Task.checkCancellation()
                self.progress = "\(index + 1)/\(ids.count) · App \(id)"
                do {
                    var extraction = SteamEngineRequest("extract", credential: credential, appID: id); extraction.includeDLC = includeDLC
                    let result = try await SteamEngine.run(extraction, executable: self.engineExecutable)
                    let prepared = try OwnedExport.files(result, steam: self.paths.steam, includeSchema: schema)
                    for file in prepared.files {
                        let target = export.appendingPathComponent(file.name)
                        try FileStore.write(file.data, to: target); try FileStore.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                    }
                    errors += prepared.warnings
                    if manifests {
                        for depot in result.depots ?? [] where !depot.key.isEmpty {
                            guard let gid = UInt64(depot.manifest), gid > 0 else { continue }
                            var request = SteamEngineRequest("manifest", credential: credential, appID: depot.sourceApp ?? depot.owner)
                            request.depotID = depot.id; request.manifestID = gid; request.depotKey = depot.key
                            request.destination = export.appendingPathComponent("\(depot.id)_\(gid).manifest").path
                            do { _ = try await SteamEngine.run(request, executable: self.engineExecutable) }
                            catch { errors.append("\(id)/\(depot.id): \(error.localizedDescription)") }
                        }
                    }
                    for depot in result.depots ?? [] where depot.key.isEmpty { errors.append("\(id)/\(depot.id): \(depot.result)") }
                } catch is CancellationError { throw CancellationError() }
                catch { errors.append("\(id): \(error.localizedDescription)") }
            }
            if !errors.isEmpty { try FileStore.write(Data(errors.joined(separator: "\n").utf8), to: export.appendingPathComponent("errors.txt")) }
            self.openFolder(export)
            self.message = Message(title: self.tr("提取完成", "Extraction complete"), detail: self.tr("结果已保存，未自动启用。", "Results saved. Import to enable.") + "\n\(export.path)\n\(errors.count) " + self.tr("项需要查看 errors.txt", "items recorded in errors.txt"))
        }
    }
}

struct OnlineAccountPanel: View {
    @EnvironmentObject var model: AppModel
    @ViewState<String> private var username = ""
    @ViewState<String> private var password = ""
    @ViewState<String> private var filter = ""
    @ViewState<String> private var app = ""
    @ViewState<Set<Int>> private var selected = []
    @ViewState<Bool> private var manifests = false
    @ViewState<Bool> private var includeDLC = true
    @ViewState<Bool> private var schema = false
    var visible: [OwnedGame] { model.ownedGames.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || String($0.id).contains(filter) } }
    var body: some View {
        Panel {
            HStack {
                Text(model.tr("SteamKit 在线提取", "SteamKit extraction")).font(.headline)
                Spacer()
                if !model.onlineAccount.isEmpty { Text(model.onlineAccount).font(.caption) }
                Button(model.tr("Steam Guard 登录", "Steam Guard sign in")) { model.onlineLogin() }.disabled(model.busy)
                Button(model.tr("读取游戏库", "Load library")) { model.onlineLibrary() }.disabled(model.busy)
                Button(model.tr("退出并忘记凭证", "Forget credential")) {
                    do { try SteamKeychain.remove(); model.onlineAccount = ""; model.ownedGames = []; selected = [] } catch { model.fail(error) }
                }.disabled(model.busy)
            }
            Text(model.tr("支持 Steam Guard 扫码、密码登录或复用本机凭证。登录令牌仅保存在 macOS 钥匙串；可批量导出当前账号有权读取的 Lua、密钥与 Manifest。", "Use Steam Guard QR, password sign-in or a local credential. Tokens are stored in macOS Keychain. Export Lua, keys and manifests accessible to this account.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(model.tr("Steam 账号", "Steam account"), text: $username).textFieldStyle(.roundedBorder)
                SecureField(model.tr("密码（不保存）", "Password (not saved)"), text: $password).textFieldStyle(.roundedBorder)
                Button(model.tr("密码登录", "Password sign in")) { model.onlinePasswordLogin(account: username, password: password); password = "" }.disabled(model.busy || username.isEmpty || password.isEmpty)
                Menu(model.tr("复用 Steam 本机登录", "Use local Steam sign-in")) {
                    ForEach(model.accounts) { account in Button(account.persona + " · " + account.name) { model.onlineLocalLogin(account) } }
                }.disabled(model.busy || model.accounts.isEmpty)
            }
            Text(model.tr("本机登录仅在点击后读取所选账号的 macOS Steam 缓存；密码和验证码只用于本次会话，成功后的令牌存入钥匙串。", "Local sign-in reads the selected account's macOS Steam cache only when clicked. Passwords and Guard codes are session-only; successful tokens go to Keychain.")).font(.caption).foregroundStyle(.secondary)
            if !model.loginQR.isEmpty {
                HStack {
                    if let qr = qrImage(model.loginQR) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 190, height: 190).padding(12).background(.white) }
                    Text(model.tr("打开手机 Steam → Steam Guard → 扫码，核对设备后确认。", "Open Steam on your phone → Steam Guard → scan and confirm the device.")).frame(maxWidth: 280)
                }.padding(.vertical)
            }
            HStack {
                TextField("AppID", text: $app).textFieldStyle(.roundedBorder).frame(width: 110)
                Button(model.tr("提取指定游戏…", "Extract game…")) { if let id = TextUtil.validID(app) { model.onlineExtract([id], manifests: manifests, includeDLC: includeDLC, schema: schema) } }.disabled(model.busy || TextUtil.validID(app) == nil)
                Button(model.tr("提取本地票据…", "Extract local tickets…")) { if let id = TextUtil.validID(app) { model.exportTickets(id) } }.disabled(model.busy || TextUtil.validID(app) == nil || !model.steamRunning)
                Toggle(model.tr("同时下载 Manifest", "Include manifests"), isOn: $manifests).toggleStyle(.checkbox).font(.caption)
            }.padding(.top, 10)
            HStack {
                Toggle(model.tr("包含有权限的 DLC 子仓库", "Include licensed DLC depots"), isOn: $includeDLC).toggleStyle(.checkbox)
                Toggle(model.tr("附带本地成就定义 Bin", "Include local achievement schema Bin"), isOn: $schema).toggleStyle(.checkbox)
            }.font(.caption)
            Text(model.tr("成就定义只读复制，不包含账号解锁状态；本机缺失时会在导出报告中标明。", "Achievement definitions are copied read-only, without account unlock states. Missing local files are recorded in the export report.")).font(.caption).foregroundStyle(.secondary)
            if !model.ownedGames.isEmpty {
                HStack {
                    TextField(model.tr("筛选正版游戏", "Filter owned games"), text: $filter).textFieldStyle(.roundedBorder)
                    Button(model.tr("选择筛选结果", "Select filtered")) { selected.formUnion(visible.map(\.id)) }
                    Button(model.tr("清除选择", "Clear selection")) { selected = [] }
                    Button(model.tr("提取所选…", "Extract selected…") + " (\(selected.count))") { model.onlineExtract(selected.sorted(), manifests: manifests, includeDLC: includeDLC, schema: schema) }.disabled(model.busy || selected.isEmpty)
                }.padding(.top)
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(visible) { game in
                            Toggle("\(game.name) · \(game.id) · \(game.type)", isOn: Binding(get: { selected.contains(game.id) }, set: { if $0 { selected.insert(game.id) } else { selected.remove(game.id) } })).toggleStyle(.checkbox).font(.caption).padding(.vertical, 3)
                        }
                    }
                }.frame(height: 240)
            }
        }.onChange(of: model.onlineAccount) { _, _ in selected = [] }
    }
    private func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(string.utf8)
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
