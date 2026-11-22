import AppKit
import MacSteamToolCore
import Testing

@testable import MacSteamTool

@Suite @MainActor struct MultiplayerFlowTests {
    @Test func absentBindingsKeepToggleOffAndDraftIntact() {
        let client = MultiplayerController(library: URL(filePath: "/missing/Multiplayer.dylib")) {
            Issue.record("A missing adapter should not launch Steam")
        }
        client.draft = "unsent"
        client.start(steamRunning: false)
        #expect(!client.running && client.failure != nil)
        client.sendChat()
        client.stop()
        #expect(client.draft == "unsent" && !client.state.active)
    }

    @Test func referenceFramesInBothDirections() throws {
        typealias W = MultiplayerWire
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let upstream = root.appendingPathComponent("Native/ConnectTool/upstream/src")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let tool = temp.appendingPathComponent("reference")
        func run(_ binary: URL, _ arguments: [String], input: Data = Data()) throws -> Data {
            let p = Process()
            let output = Pipe()
            let stdin = Pipe()
            p.executableURL = binary
            p.arguments = arguments
            p.standardOutput = output
            p.standardInput = stdin
            try p.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            let result = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw AppFailure("Reference oracle exited \(p.terminationStatus)")
            }
            return result
        }
        _ = try run(
            URL(filePath: "/usr/bin/xcrun"),
            [
                "clang++", "-std=c++23", "-fexperimental-library",
                "-I", upstream.path, root.appendingPathComponent("Tests/ConnectToolReference/frames.cpp").path,
                upstream.appendingPathComponent("network/protocol/multiplex_protocol.cpp").path,
                upstream.appendingPathComponent("network/vpn/node_identity.cpp").path,
                upstream.appendingPathComponent("network/vpn/sha256.cpp").path, "-o", tool.path,
            ])
        let id: UInt64 = 76_561_198_012_345_678
        let ip: UInt32 = 0x0a01_0203
        let timestamp: UInt64 = 0x0102_0304_0506_0708
        let node = W.node(id)
        let plain = W.control(ip: ip, node: node)
        let timed = W.control(ip: ip, node: node, timestamp: timestamp)
        let route = W.little64(id) + W.ipv4(ip)
        let ipPacket = Data([0x45, 0, 0, 20, 0, 1, 0, 0, 64, 17, 0, 0, 10, 1, 2, 3, 255, 255, 255, 255])
        let packets: [(String, W.VPN, Data)] = [
            ("probe", .probe, plain), ("conflict", .conflict, timed), ("announce", .announce, plain),
            ("release", .release, plain), ("heartbeat", .heartbeat, timed), ("ack", .heartbeatAck, Data()),
            ("hello", .hello, Data()),
            ("route", .routes, route), ("ip", .ip, node + W.ipv4(ip) + ipPacket),
        ]
        var ours = [String: Data]()
        for (name, kind, body) in packets { ours[name] = W.envelope(kind, body) }
        for (name, close, bytes) in [("tcp", false, route), ("close", true, Data()), ("empty", false, Data())] {
            ours[name] = W.encode(.init(id: "aB12z9", close: close, payload: bytes))
        }
        let reference = try run(tool, [])
        let windows = try Data(contentsOf: root.appendingPathComponent("Tests/ConnectToolReference/win64.frames"))
        #expect(reference == windows)
        var verified = Set<String>()
        for line in String(decoding: reference, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")
            let key = String(fields[0])
            let hex = Array(fields[1].utf8)
            let data = Data(
                stride(from: 0, to: hex.count, by: 2).map {
                    UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)!
                })
            #expect(ours[key] == data)
            if let (_, kind, body) = packets.first(where: { $0.0 == key }) {
                let parsed = try #require(W.decodeVPN(data))
                #expect(parsed.0 == kind && parsed.1 == body)
            } else {
                let frame = try #require(W.decodeTCP(data))
                #expect(
                    frame.id == "aB12z9" && frame.close == (key == "close")
                        && frame.payload == (key == "tcp" ? route : Data()))
            }
            verified.insert(key)
        }
        #expect(verified == Set(ours.keys))
        let text = ours.map { key, bytes in key + " " + bytes.map { String(format: "%02x", $0) }.joined() }.joined(
            separator: "\n")
        _ = try run(tool, ["verify"], input: Data(text.utf8))
        if let runner = ProcessInfo.processInfo.environment["MP_TEST_WIN64_ORACLE"] {
            _ = try run(URL(filePath: runner), ["verify"], input: Data(text.utf8))
        }
        #expect(W.decodeTCP(Data(repeating: 0, count: 11)) == nil)
        #expect(W.decodeVPN(Data([14, 0, 2, 0])) == nil)
        #expect(W.envelope(.ip, Data(count: 65536)) == nil)
    }
    @Test func roomChatAndGameStreamsAgainstReferencePeer() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let native = root.appendingPathComponent("Native/ConnectTool/upstream/src")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("fixture.dylib")
        let compiler = Process()
        compiler.executableURL = URL(filePath: "/usr/bin/xcrun")
        compiler.arguments = [
            "clang++", "-std=c++23", "-fexperimental-library", "-dynamiclib",
            "-I", native.path, "-I", root.appendingPathComponent("Sources/CMultiplayer").path,
            root.appendingPathComponent("Tests/ConnectToolReference/steam_fixture.cpp").path,
            native.appendingPathComponent("network/protocol/multiplex_protocol.cpp").path,
            native.appendingPathComponent("network/vpn/node_identity.cpp").path,
            native.appendingPathComponent("network/vpn/ip_negotiator.cpp").path,
            native.appendingPathComponent("network/vpn/sha256.cpp").path, "-o", library.path,
        ]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let image = try #require(dlopen(library.path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(image) }
        let probe = unsafeBitCast(
            try #require(dlsym(image, "MPFixture")), to: (@convention(c) (Int32) -> Int32).self)
        func until(_ reason: String, _ check: () -> Bool) async throws {
            for _ in 0..<250 {
                if check() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw AppFailure(reason)
        }
        var launchCount = 0
        let client = MultiplayerController(library: library) {
            launchCount += 1
            if launchCount == 1 {
                #expect(probe(19) == 0)
                throw AppFailure("Steam launch failed")
            }
        }
        defer { client.stop() }
        let originalID = ProcessInfo.processInfo.environment["SteamAppId"]
        _ = probe(17)
        client.start(steamRunning: false)
        client.start(steamRunning: false)
        try await until("Surface a failed Steam launch while continuing to poll") { client.steamLaunchError != nil }
        #expect(client.running && client.state.steamReady == false && launchCount == 1)
        try await until("Poll while Steam is closed") { probe(19) >= 1 }
        try await until("Retry Steamworks without reopening the client") { probe(19) >= 2 }
        #expect(launchCount == 1)
        client.requestSteamLaunch()
        try await until("Explicitly reopen Steam") { launchCount == 2 }
        _ = probe(18)
        try await until("Connect automatically after sign-in") { client.state.steamReady == true }
        #expect(client.steamLaunchError == nil && launchCount == 2)
        client.start(steamRunning: true)
        try #require(client.state.steamReady == true)
        #expect(ProcessInfo.processInfo.environment["SteamAppId"] == originalID)
        client.mode = 0
        client.roomName = "测试房间"
        client.published = true
        client.port = String(probe(1))
        client.connect(host: true)
        try await until("Host lobby") { client.state.isHost == true }
        #expect(probe(4) == 1 && client.state.lobbies?.count == 1)
        let roomID = try #require(client.state.lobbyId)
        #expect(roomID == "109775241000000001" && client.state.members?.count == 2)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(CopyValue(title: "房间 ID", value: roomID).copy(to: board))
        #expect(board.string(forType: .string) == "109775241000000001")
        _ = probe(20)
        try await until("Lobby member left") { client.state.members?.count == 1 }
        _ = probe(21)
        try await until("Lobby member joined") { client.state.members?.count == 2 }
        client.draft = "你好，Steam"
        client.sendChat()
        try await until("Chat callback") { client.state.messages?.count == 1 }
        try #require(client.draft.isEmpty)
        client.pin(try #require(client.state.messages?.first))
        #expect(probe(11) == 1 && client.state.pinned?.message == "你好，Steam")
        client.clearPin()
        client.invite("76561198012345679")
        #expect(probe(8) == 1 && client.state.pinned == nil)
        _ = probe(2)
        try await until("Two independent TCP streams on loopback") { probe(3) == 2 }
        _ = probe(10)
        client.disconnect()
        #expect(probe(9) == 2 && probe(12) == 1)
        #expect(client.state.lobbyId == nil && client.state.members?.isEmpty == true)
        client.target = "109775241000000001"
        client.bindPort = String(probe(13))
        client.connect(host: false)
        try await until("Guest loopback listener") { client.state.lobbyId != nil && probe(14) == 1 }
        try await until("Guest TCP bytes echoed through original decoder and graceful close") { probe(15) == 1 }
        client.disconnect()
        _ = probe(16)
        client.connect(host: false)
        try await until("utun IPv4 in both directions using 1.6.0 envelopes") { probe(5) == 1 }
        #expect(client.mode == 1 && client.state.hostSteamId == "76561198012345679")
        _ = probe(17)
        try await until("Steam closed; clear the room and keep multiplayer enabled") {
            client.running && client.state.steamReady != true && client.state.lobbyId == nil
        }
        _ = probe(18)
        try await until("Reconnect when Steam returns") { client.state.steamReady == true }
        #expect(launchCount == 2)
        client.stop()
        #expect(probe(6) == 3 && probe(7) == 2 && probe(0) == 0)
        #expect(client.state.active == false && !client.running)
        _ = probe(17)
        client.start(steamRunning: false)
        client.stop()
        let attempts = probe(19)
        try await Task.sleep(for: .milliseconds(3200))
        #expect(launchCount == 2 && probe(19) == attempts)
        _ = probe(18)
        client.start(steamRunning: true)
        try #require(client.state.steamReady == true)
        await Task.yield()
        #expect(launchCount == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MP_TEST_BUNDLED_SDK"] != nil))
    func packagedSteamworksLoadsAndStopsInsideHost() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MP_TEST_BUNDLED_SDK"])
        let client = MultiplayerController(library: URL(filePath: path)) {}
        for _ in 0..<2 {
            client.start(steamRunning: true)
            #expect(client.running && client.state.steamReady != nil)
            #expect(!client.state.active)
            client.stop()
            #expect(!client.running && client.state.steamReady == nil)
        }
    }

}
