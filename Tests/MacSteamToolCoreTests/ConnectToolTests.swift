import Testing
import Foundation
@testable import MacSteamToolCore

@Suite struct ConnectToolTests {
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
