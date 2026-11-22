#!/usr/bin/env python3
"""Read-only game API startup through the installed NotProton Steam shim.

Uses an explicitly supplied PRIVATE prefix under this project's work directory.
It never starts the game executable or writes achievements. Steam must be online.
The authorized installed test game is Probably Stolen (4348910), not Spacewar.
"""
from pathlib import Path
import argparse
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--private-steam-root", type=Path, required=True)
parser.add_argument("--game-data", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
private = args.private_steam_root.resolve()
assert private.is_relative_to(ROOT / "work") and private != ROOT / "work"
out = args.output.resolve()
assert out.is_relative_to(ROOT / "work")
out.mkdir(parents=True, exist_ok=True)
helper = out / "probe/GameStartupProbe.exe"
subprocess.run([str(ROOT / "work/dotnet/dotnet"), "publish",
                str(ROOT / "Tests/GameStartupProbe/GameStartupProbe.csproj"),
                "-c", "Release", "-o", str(helper.parent)], check=True)
plan = json.loads(subprocess.check_output([str(ROOT / ".build/debug/MacSteamToolInspect"),
                  "--wine-plan", str(private), "4348910", str(helper)]))
env = os.environ.copy()
env.update(plan["environment"])
assert Path(env["WINEPREFIX"]).resolve().is_relative_to(private)
env["WINEDEBUG"] = "-all,err+steam,warn+steamclient"
native = Path(env["STEAM_COMPAT_CLIENT_INSTALL_PATH"])
overlay = Path.home() / "Library/Application Support/notproton/overlay-shim.dylib"
win = lambda p: "Z:" + str(p.resolve()).replace("/", "\\")
rows = []
for i in range(4):
    e = env.copy()
    if i % 2:
        e.update(SteamClientLaunch="1", SteamEnv="1", SteamOverlayGameId="4348910",
                 DYLD_INSERT_LIBRARIES=":".join(str(p) for p in [overlay, native / "steamloader.dylib", native / "gameoverlayrenderer.dylib"]),
                 NOTPROTON_OVERLAY_SHIM=str(overlay))
    target = out / f"startup-{i + 1}.json"
    if target.exists(): target.unlink()  # Never accept stale output as a successful run.
    start = time.monotonic()
    try:
        p = subprocess.run([plan["executable"], r"C:\Program Files (x86)\Steam\steam.exe",
                            win(helper), win(args.game_data / "Managed/com.rlabrecque.steamworks.net.dll"),
                            win(args.game_data / "Plugins/x86_64/steam_api64.dll"), win(target)],
                           env=e, capture_output=True, text=True, timeout=45)
        (out / f"startup-{i + 1}.log").write_text(p.stdout + p.stderr)
        report = json.loads(target.read_text())
        ok = p.returncode == 0 and report.get("result") == "k_ESteamAPIInitResult_OK"
        rows.append(dict(run=i + 1, overlay=bool(i % 2), ok=ok, seconds=round(time.monotonic()-start, 2)))
        print(rows[-1], flush=True)
    finally:
        # Only the explicitly verified private prefix's server is terminated.
        subprocess.run([env["WINESERVER"], "-k"], env=env, check=True, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([env["WINESERVER"], "-w"], env=env, check=True, timeout=25)
    (out / "summary.json").write_text(json.dumps(rows, indent=2))
assert all(row["ok"] for row in rows)
print("PASS: shim -> game's own Steamworks.NET, four cold private-prefix runs. No game/save/achievement writes.")
