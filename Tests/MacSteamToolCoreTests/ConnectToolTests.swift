import Testing
import Foundation
@testable import MacSteamToolCore

@Suite struct ConnectToolTests {
    @Test func fragmentedAndCoalescedFramesKeepIDsAndUnicode() throws {
        let value = #"{"type":"state","state":{"steamReady":true,"lobbyId":"109775240917155841","selfSteamId":"76561197960265729","messages":[{"steamId":"76561197960265729","message":"联机 🎮\n第二行","timestamp":"2026-11-11T12:00:00.123Z","row":0}],"pinned":{}}}"#
        let bytes = Data((value + "\n{\"type\":\"ack\",\"id\":9}\n").utf8)
        var parser = ConnectFrames(), events: [ConnectEvent] = []
        for byte in bytes { events += try parser.append(Data([byte])) }
        #expect(events.count == 2)
        #expect(events[0].state?.lobbyId == "109775240917155841")
        #expect(events[0].state?.messages?.first?.message == "联机 🎮\n第二行")
        #expect(events[1].id == 9)
        var batched = ConnectFrames()
        #expect(try batched.append(bytes).count == 2)
    }
    @Test func malformedOrUnboundedServiceOutputFailsClosed() throws {
        var malformed = ConnectFrames()
        #expect(throws: (any Error).self) { try malformed.append(Data("Steam log\n".utf8)) }
        var oversized = ConnectFrames()
        #expect(throws: (any Error).self) { try oversized.append(Data(repeating: 65, count: 32 * 1024 * 1024 + 1)) }
    }
    @Test func emptyPinAndDisconnectedStateAreValid() throws {
        let event = try JSONDecoder().decode(ConnectEvent.self, from: Data(#"{"type":"state","state":{"steamReady":false,"lobbyId":"","messages":[],"pinned":{},"friends":[]}}"#.utf8))
        #expect(event.state?.active == false)
        #expect(event.state?.pinned?.message == nil)
    }

    @Test func homeShowsTheAddressForTheCurrentRoomAndRole() throws {
        var state = try JSONDecoder().decode(ConnectState.self, from: Data(#"{"isConnected":true,"connectionMode":1,"tunLocalIp":"10.0.0.7","hostSteamId":"12","members":[{"steamId":"12","displayName":"Host","ip":"10.0.0.2"}]}"#.utf8))
        #expect(state.gameAddress == "10.0.0.2")
        state.members = []
        #expect(state.gameAddress == nil)
        state.isHost = true
        #expect(state.gameAddress == "10.0.0.7")
        state.connectionMode = 0
        state.localPort = 7777
        state.localBindPort = 8888
        #expect(state.gameAddress == "localhost:7777")
        state.isHost = false
        #expect(state.gameAddress == "localhost:8888")
        state.isConnected = false
        #expect(state.gameAddress == nil)
    }
}
