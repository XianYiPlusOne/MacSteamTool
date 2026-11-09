import Foundation
import Testing
import Darwin
@testable import FluentCore

@Suite struct SteamSessionFlowTests {
    func helper(root: URL) throws -> URL {
        let url = root.appendingPathComponent("fake-engine")
        let script = #"""
#!/usr/bin/env python3
import json,os,sys,time,stat
from pathlib import Path
request,output=map(Path,sys.argv[1:]);r=json.loads(request.read_text())
assert stat.S_IMODE(request.stat().st_mode)==0o600
assert stat.S_IMODE(request.parent.stat().st_mode)==0o700
Path(r['destination']).write_text(json.dumps({'pid':os.getpid(),'folder':str(request.parent)}))
def write(path,value):
    temp=Path(str(path)+'.new');temp.write_text(json.dumps(value));temp.replace(path)
status=Path(str(output)+'.status')
if r['operation']=='stall':
    while True: time.sleep(.1)
write(status,{'state':'qr','url':'https://example.invalid/test-qr'})
time.sleep(.4)
write(status,{'state':'guard','requestID':'challenge-1','prompt':'fixture guard'})
reply=Path(str(status)+'.reply')
end=time.monotonic()+5
while not reply.exists() and time.monotonic()<end: time.sleep(.02)
answer=json.loads(reply.read_text())
assert answer['requestID']=='challenge-1' and answer['code']=='ABCDE'
write(output,{'ok':True,'account':r['account'],'token':'synthetic-refresh-token'})
"""#
        try FileStore.write(Data(script.utf8), to: url); try FileStore.fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    @Test func processRequestQRGuardResponseAndPrivateCleanup() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(root); defer { try? FileStore.fm.removeItem(at: root) }
        let exe = try helper(root: root), marker = root.appendingPathComponent("marker.json"), events = LoginEvents()
        var request = SteamEngineRequest("login-password"); request.account = "fixture"; request.password = "test-only"; request.destination = marker.path
        let result = try await SteamEngine.run(request, executable: exe, status: { await events.qr($0) }, challenge: { prompt in
            #expect(prompt == "fixture guard"); await events.guardPrompt(); return "ABCDE"
        })
        #expect(result.account == "fixture"); #expect(result.token == "synthetic-refresh-token")
        #expect(await events.urls == ["https://example.invalid/test-qr"]); #expect(await events.guards == 1)
        let recorded = try #require(JSONSerialization.jsonObject(with: FileStore.read(marker)) as? [String: Any])
        let folder = try #require(recorded["folder"] as? String)
        #expect(!FileStore.fm.fileExists(atPath: folder))
    }
    @Test func cancellationKillsHelperAndRemovesRequestDirectory() async throws {
        let root = FileStore.fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileStore.mkdir(root); defer { try? FileStore.fm.removeItem(at: root) }
        let exe = try helper(root: root), marker = root.appendingPathComponent("marker.json")
        var request = SteamEngineRequest("stall"); request.destination = marker.path
        let childRequest = request
        let task = Task { try await SteamEngine.run(childRequest, executable: exe) }
        for _ in 0..<100 { if FileStore.fm.fileExists(atPath: marker.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let recorded = try #require(JSONSerialization.jsonObject(with: FileStore.read(marker)) as? [String: Any])
        task.cancel(); await #expect(throws: (any Error).self) { try await task.value }
        let pid = try #require(recorded["pid"] as? Int32), folder = try #require(recorded["folder"] as? String)
        #expect(kill(pid, 0) != 0); #expect(!FileStore.fm.fileExists(atPath: folder))
    }
}
private actor LoginEvents {
    var urls: [String] = []; var guards = 0
    func qr(_ url: String) { urls.append(url) }
    func guardPrompt() { guards += 1 }
}
