import Foundation
import MacSteamToolCore

@MainActor final class TunHelperController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var checked = false
    @Published private(set) var message = "正在检查虚拟网卡助手… / Checking virtual network helper…"
    @Published private(set) var detail = ""
    let helper: URL
    let plist: URL
    var run: (URL, [String]) async throws -> (Int32, String) = { executable, arguments in
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CONNECTTOOL_TUN_HELPER_SOCKET")
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") { environment.removeValue(forKey: key) }
        return try await ProcessRunner.run(executable, arguments, environment: environment)
    }

    init(resources: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/ConnectTool/Resources")) {
        helper = resources.appendingPathComponent("connecttool-tun-daemon")
        plist = resources.appendingPathComponent("com.connecttool.tunhelper.plist")
    }
    func check() async {
        guard !busy else { return }
        busy = true; defer { busy = false; checked = true }
        message = "正在测试虚拟网卡… / Testing virtual network interface…"; detail = ""
        do { try await probe() }
        catch { ready = false; message = "虚拟网卡助手尚未就绪，可启用或修复 / Enable or repair the virtual network helper"; detail = error.localizedDescription }
    }
    private func probe() async throws {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AppFailure("应用内缺少网卡助手，请使用完整应用包 / Bundled helper is missing") }
        let (code, text) = try await run(helper, ["--probe"])
        guard code == 0, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("OK utun") else {
            throw AppFailure(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "网卡创建测试失败（\(code)） / Interface check failed" : text)
        }
        ready = true; message = "虚拟网卡已就绪，创建测试通过 / Virtual network ready; interface check passed"; detail = ""
    }
    func repair() async {
        guard !busy else { return }
        busy = true; ready = false; detail = ""; defer { busy = false; checked = true }
        do {
            message = "正在校验安装文件… / Verifying helper files…"
            let (signature, diagnostic) = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", helper.path])
            guard signature == 0 else { throw AppFailure("网卡助手签名校验失败 / Helper signature failed: \(diagnostic)") }
            let command = try TunHelperSetup.installScript(helper: helper, plist: plist,
                helperHash: FileStore.hash(FileStore.read(helper)), plistHash: FileStore.hash(FileStore.read(plist)))
            message = "请在 macOS 弹窗中授权，完成后会自动检测 / Authorize in the macOS dialog; verification follows automatically"
            let (code, output) = try await run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", TunHelperSetup.appleScript(command)])
            guard code == 0 else {
                if output.contains("-128") { message = "已取消授权，可随时重试 / Authorization cancelled; retry when ready"; return }
                throw AppFailure(output.isEmpty ? "安装失败（\(code)） / Installation failed" : output)
            }
            // A successful root process is not sufficient: the signed-in user
            // must be able to connect and receive a usable utun descriptor too.
            message = "正在验证当前账户的虚拟网卡权限… / Verifying virtual network access…"
            try await probe()
        } catch {
            ready = false; message = "虚拟网卡配置失败，可重试修复 / Virtual network setup failed; repair to retry"
            detail = String(error.localizedDescription.suffix(4000))
        }
    }
}
