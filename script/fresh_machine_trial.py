#!/usr/bin/env python3
"""Reversible live-machine fixture. Does not change HOME or copy login data.

stage -> park -> run the application's normal setup UI -> restore
Every rename is journaled outside the temporarily inaccessible backup vault.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "work/fresh-machine-e2e"
STATE = EVIDENCE / "state.json"
SUPPORT = Path.home() / "Library/Application Support"
APP_ID = "5245810"

def save(state):
    temp = STATE.with_suffix(".pending")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    temp.chmod(0o600)
    temp.replace(STATE)

def idle():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid,comm"], text=True)
    for row in rows.splitlines()[1:]:
        fields = row.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[1].endswith(("/steam_osx", "/MacSteamTool", "/FluentSteam")):
            raise RuntimeError("Quit Steam and MacSteamTool before moving their files")

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def app_data():
    current, legacy = SUPPORT / "MacSteamTool", SUPPORT / "FluentSteamMac"
    return legacy if not current.exists() and legacy.exists() else current

def protected_files():
    files = [SUPPORT / "macsteam/config.yaml", app_data() / "settings.json",
             SUPPORT / "Steam/config/config.vdf", Path("/Applications/Steam.app/Contents/Info.plist")]
    for prefix in ["pfx", "fluent-free/pfx"]:
        root = SUPPORT / f"Steam/steamapps/compatdata/{APP_ID}/{prefix}/drive_c/users/steamuser/AppData/LocalLow"
        if root.exists():
            files.extend(p for p in root.rglob("*") if p.is_file() and not p.is_symlink())
    return {str(p): sha(p) for p in files if p.is_file()}

def stage():
    if STATE.exists() and json.loads(STATE.read_text())["phase"] != "restored":
        raise RuntimeError("An existing trial must be restored first")
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    EVIDENCE.chmod(0o700)
    trial = uuid.uuid4().hex
    vault = SUPPORT / ("FluentFreshMachineTrial-" + trial)
    vault.mkdir(mode=0o700)
    assets = EVIDENCE / ("assets-" + trial)
    assets.mkdir(mode=0o700)
    game = SUPPORT / "Steam/steamapps/common/ForgeTax"
    subprocess.run(["/bin/cp", "-cR", str(game), str(assets / "ForgeTax")], check=True)
    for source, name in [(SUPPORT / f"Steam/steamapps/appmanifest_{APP_ID}.acf", f"appmanifest_{APP_ID}.acf"),
                         (app_data() / f"Lua/{APP_ID}.lua", f"{APP_ID}.lua")]:
        shutil.copy2(source, assets / name)
        (assets / name).chmod(0o600)
    paths = [Path("/Applications") / name for name in
             ("Steam.app", "macSteam Config.app", "NotProton.app", "CrossOver.app")]
    paths += [SUPPORT / name for name in ("Steam", "macsteam", "notproton", "FluentSteamMac", "MacSteamTool", "CrossOver")]
    entries = [{"source": str(p), "stored": str(vault / str(i)), "moved": False,
                "existed": p.exists()} for i, p in enumerate(paths)]
    state = {"phase": "staged", "created": time.time(), "vault": str(vault),
             "assets": str(assets), "entries": entries, "protected": protected_files()}
    save(state)
    print("Staged game files and preservation hashes; no application or user environment moved.")

def park():
    idle()
    state = json.loads(STATE.read_text())
    if state["phase"] != "staged":
        raise RuntimeError("Trial is not staged")
    state["phase"] = "parking"; save(state)
    for entry in state["entries"]:
        if entry["existed"]:
            os.rename(entry["source"], entry["stored"])
            entry["moved"] = True; save(state)
    Path(state["vault"]).chmod(0)
    state["phase"] = "parked"; save(state)
    print("Original environment parked; vault inaccessible; production setup paths are absent.")

def restore():
    idle()
    state = json.loads(STATE.read_text())
    if state["phase"] == "restored":
        print("Already restored"); return
    vault = Path(state["vault"]); vault.chmod(0o700)
    state["phase"] = "restoring"; save(state)
    generated = EVIDENCE / ("generated-" + vault.name)
    generated.mkdir(exist_ok=True, mode=0o700)
    for i, entry in reversed(list(enumerate(state["entries"]))):
        source, stored = Path(entry["source"]), Path(entry["stored"])
        # Keep any data created under the new product name during a legacy trial.
        if source == SUPPORT / "MacSteamTool" and not entry["existed"] and source.exists():
            source.rename(generated / str(i))
        # Recover the small rename-to-journal window as well.
        if not entry["moved"] and not stored.exists():
            continue
        if source.exists():
            destination = generated / str(i)
            if destination.exists():
                raise RuntimeError("Refusing to replace retained test output")
            os.rename(source, destination)
        os.rename(stored, source)
        entry["moved"] = False; save(state)
    mismatches = [p for p, digest in state["protected"].items() if not Path(p).is_file() or sha(Path(p)) != digest]
    if mismatches:
        state["verification_mismatches"] = mismatches; save(state)
        raise RuntimeError("Restored files require inspection; see state journal")
    state["phase"] = "restored"; state["restored"] = time.time(); state["generated"] = str(generated)
    save(state)
    print(f"Original environment restored; {len(state['protected'])} configuration/save hashes match. Test installation retained separately.")

if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) == 2 else ""
    if command == "stage": stage()
    elif command == "park": park()
    elif command == "restore": restore()
    elif command == "status":
        state = json.loads(STATE.read_text())
        print(json.dumps({key: state.get(key) for key in ("phase", "created", "restored", "generated")}, indent=2))
    else: raise SystemExit("Usage: fresh_machine_trial.py stage|park|restore|status")
