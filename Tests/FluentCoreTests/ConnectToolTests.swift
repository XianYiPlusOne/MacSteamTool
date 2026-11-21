import Testing
import Foundation
@testable import FluentCore

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
}
