import AppKit
import Darwin
import FluentCore

/// A persistent, windowless ConnectTool service. SwiftUI owns every visible control.
@MainActor final class MultiplayerController: ObservableObject {
    @Published private(set) var state = ConnectState()
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published var failure: String?
    @Published var mode = 1
    @Published var roomName = ""
    @Published var target = ""
    @Published var port = "25565"
    @Published var bindPort = "8888"
    @Published var published = false
    @Published var draft = ""
    @Published var friendFilter = ""
    @Published var lobbyFilter = ""
    @Published var lobbySort = 0
    @Published var reminders = true
    @Published var useProxy = false
    let tun = TunHelperController()
    let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var sequence = 0
    private var acknowledgements: [Int: (Bool) -> Void] = [:]
    private var observer: NSObjectProtocol?
    private var lastMessage: String?
    private var receivedState = false

    init(executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Helpers/ConnectTool/MacOS/FluentConnect")) {
        self.executable = executable
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; try? input?.close() }
    var isBundled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
    func start() {
        guard process == nil, !starting else { return }
        guard isBundled else { failure = "联机服务缺失，请使用完整应用包 / Multiplayer service is missing"; return }
        starting = true; failure = nil; state = ConnectState(); receivedState = false; lastMessage = nil
        let token = UUID(); generation = token
        let p = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.executableURL = executable; p.currentDirectoryURL = executable.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CONNECTTOOL_TUN_HELPER_SOCKET")
        env["SteamAppId"] = "480"; env["SteamGameId"] = "480"
        for key in Array(env.keys) where key.hasPrefix("DYLD_") || key.hasPrefix("QT_") { env.removeValue(forKey: key) }
        p.environment = env; p.standardInput = stdinPipe; p.standardOutput = stdoutPipe; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] child in Task { @MainActor in
            guard let self, self.generation == token else { return }
            self.process = nil; self.input = nil; self.running = false; self.starting = false; self.state = ConnectState()
            let callbacks = self.acknowledgements.values; self.acknowledgements.removeAll(); callbacks.forEach { $0(false) }
            self.failure = "联机服务已退出（\(child.terminationStatus)），可重新连接 / Multiplayer service exited; reconnect to retry"
        } }
        do {
            try p.run(); process = p; input = stdinPipe.fileHandleForWriting
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let reader = stdoutPipe.fileHandleForReading
            DispatchQueue(label: "dev.fluentsteam.connecttool.read").async { [weak self] in
                var frames = ConnectFrames()
                do {
                    // Foundation's read(upToCount:) may wait to fill the request on
                    // a pipe. POSIX read delivers even a single small ACK immediately.
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        let events = try frames.append(Data(buffer.prefix(count)))
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token else { return }
                            for event in events { self.receive(event) }
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token else { return }
                        self.stop(); self.failure = message
                    }
                }
                try? reader.close()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.generation == token, self.starting else { return }
                self.stop(); self.failure = "联机服务启动超时，请确认已安装 Rosetta 2 / Service startup timed out; check Rosetta 2"
            }
        } catch { starting = false; failure = error.localizedDescription }
    }
    private func receive(_ event: ConnectEvent) {
        if event.type == "state", let value = event.state {
            if !receivedState {
                receivedState = true
                if roomName.isEmpty { roomName = value.roomName ?? "" }
                send("filterFriends", ["text": friendFilter])
                send("filterLobbies", ["text": lobbyFilter, "sort": lobbySort])
            }
            if let latest = value.messages?.last {
                if reminders, let previous = lastMessage, previous != latest.id, latest.isSelf != true, !NSApp.isActive {
                    NSSound(named: "Glass")?.play(); NSApp.requestUserAttention(.informationalRequest)
                }
                lastMessage = latest.id
            }
            state = value; running = true; starting = false
            if value.active { mode = value.connectionMode ?? mode }
        } else if event.type == "error" {
            failure = event.message ?? "联机操作失败 / Multiplayer operation failed"
            if let id = event.id { acknowledgements.removeValue(forKey: id)?(false) }
        } else if event.type == "ack", let id = event.id { acknowledgements.removeValue(forKey: id)?(true) }
    }
    func send(_ operation: String, _ values: [String: Any] = [:], completion: ((Bool) -> Void)? = nil) {
        guard let input, process?.isRunning == true else { completion?(false); return }
        sequence += 1; let id = sequence
        var command = values; command["operation"] = operation; command["id"] = id
        do {
            var bytes = try JSONSerialization.data(withJSONObject: command); bytes.append(10)
            guard bytes.count <= 65536 else { throw AppFailure("联机请求过大 / Multiplayer request too large") }
            acknowledgements[id] = completion
            try input.write(contentsOf: bytes)
            if completion != nil {
                let token = generation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, self.generation == token, let callback = self.acknowledgements.removeValue(forKey: id) else { return }
                    self.failure = "操作响应超时，请检查房间状态 / Response timed out; check room status"; callback(false)
                }
            }
        } catch { acknowledgements.removeValue(forKey: id)?(false); failure = error.localizedDescription }
    }
    func connect(host: Bool) {
        guard let p = Int(port), let b = Int(bindPort), (1...65535).contains(p), (1...65535).contains(b) else { failure = "端口须为 1–65535 / Ports must be 1–65535"; return }
        guard host || UInt64(target.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { failure = "请输入有效的房间 ID 或 SteamID64 / Enter a valid room ID or SteamID64"; return }
        failure = nil
        send("configure", ["mode": mode, "port": p, "bindPort": b, "roomName": roomName, "published": published, "target": target.trimmingCharacters(in: .whitespacesAndNewlines)]) { [weak self] ok in
            if ok { self?.send(host ? "host" : "join") }
        }
    }
    func sendChat() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= 4000 else { failure = "消息超过 4000 字节 / Message is too long"; return }
        send("chat", ["text": text]) { [weak self] ok in if ok, self?.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { self?.draft = "" } }
    }
    func openFriend(_ person: ConnectPerson) {
        guard UInt64(person.steamId) != nil, let url = URL(string: "https://steamcommunity.com/profiles/\(person.steamId)/") else { return }
        NSWorkspace.shared.open(url)
    }
    func pin(_ message: ConnectChat) {
        guard let row = message.row, let text = message.message, let steamId = message.steamId, let timestamp = message.timestamp else { return }
        send("pin", ["row": row, "text": text, "steamId": steamId, "timestamp": timestamp])
    }
    func stop() {
        let child = process
        send("quit"); try? input?.close(); input = nil
        generation = UUID(); process = nil; running = false; starting = false; state = ConnectState()
        acknowledgements.removeAll()
        // EOF lets the engine leave its lobby and stop TCP/TUN before exiting.
        if let child { DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if child.isRunning { child.terminate() } } }
    }
    func downloadUpdate() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "connecttool-qt.dmg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send("downloadUpdate", ["proxy": useProxy, "path": url.path])
    }
}
