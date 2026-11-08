#!/usr/bin/env python3
"""Exercise the real worker binary with a fake native library; never connect to Steam."""
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--product", "FluentSteamWorker"], cwd=ROOT, check=True)
bin_dir = pathlib.Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
(ROOT / "work").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="worker-test-", dir=ROOT / "work") as temp:
    folder = pathlib.Path(temp)
    library = folder / "steamclient.dylib"
    subprocess.run(["xcrun", "clang++", "-dynamiclib", "-std=c++17", str(ROOT / "Tests/Fixtures/FakeSteam.cpp"), "-o", str(library)], check=True)

    def request(app=100, changes=None, operation=None, source_id=None):
        source, output = folder / "request.json", folder / "response.json"
        output.unlink(missing_ok=True)
        source.write_text(json.dumps({"appID": app, "library": str(library), "changes": changes or [], "operation": operation, "schemaSourceSteamID": source_id}))
        completed = subprocess.run([str(bin_dir / "FluentSteamWorker"), str(source), str(output)], capture_output=True, timeout=8)
        response = json.loads(output.read_text())
        assert (completed.returncode == 0) == response["ok"]
        return response

    loaded = request()
    assert loaded["ok"] and len(loaded["achievements"]) == 2 and not loaded["stored"]
    saved = request(changes=[{"id": "FIRST", "expected": False, "achieved": True}])
    assert saved["ok"] and saved["stored"] and saved["achievements"][0]["achieved"]
    relocked = request(changes=[{"id": "SECOND", "expected": True, "achieved": False}])
    assert relocked["ok"] and not relocked["achievements"][1]["achieved"]
    assert not request(app=481)["ok"]  # wrong Steam AppID context
    assert not request(changes=[{"id": "FIRST", "expected": True, "achieved": False}])["ok"]
    assert not request(app=483, changes=[{"id": "FIRST", "expected": False, "achieved": True}])["ok"]  # server rejects StoreStats
    assert not request(app=484)["ok"]  # corrupt native result size
    assert not request(changes=[{"id": "UNKNOWN", "expected": False, "achieved": True}])["ok"]
    assert request(app=485)["ok"]  # 012 fallback uses RequestUserStats as well
    assert not request(app=486)["ok"]  # invalid async call must fail immediately
    assert request(app=487)["ok"]  # ignore other account, mod GameID and user handle callbacks
    assert not request(app=488)["ok"]  # EResult=2 is not an empty success
    schema = request(operation="schema", source_id=76561197960265730)
    assert schema["ok"] and schema["schemaLoaded"] and not schema["achievements"] and not schema["stored"]
    assert not request(operation="schema", source_id=76561197960265730, changes=[{"id":"FIRST","expected":False,"achieved":True}])["ok"]
    assert not request(source_id=76561197960265730)["ok"]
    print("PASS: 15 isolated native worker scenarios (load, unlock, relock, context mismatch, conflict, failed server acknowledgement, oversized result, unknown achievement). No real Steam connection.")
