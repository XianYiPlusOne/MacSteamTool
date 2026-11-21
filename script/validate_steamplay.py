#!/usr/bin/env python3
"""Exercise a separately prepared steamplay-mac runner, without installing into Steam.

Only writes below work/steamplay-validation. Requires the pinned upstream release,
its hash-verified Valve bridge, and Native/SteamPlayValidation/probe.c compiled for
Windows. Never invokes upstream install.sh or changes HOME. No CrossOver paths or
credentials are inherited by the Windows processes.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "work/steamplay-validation"


def windows(path):
    return "Z:" + str(path.resolve()).replace("/", "\\")


def descendants(pid):
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
    pairs = [tuple(map(int, line.split())) for line in rows.splitlines() if line.strip()]
    found = {pid}
    while True:
        expanded = found | {child for child, parent in pairs if parent in found}
        if expanded == found:
            return found
        found = expanded


def loaded_files(pid):
    pids = ",".join(map(str, descendants(pid)))
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-p", pids, "-Fn"],
                            capture_output=True, text=True, timeout=10)
    return {line[1:] for line in result.stdout.splitlines()
            if line.startswith("n/") and (line.endswith((".dylib", ".so", ".dll"))
                                           or "/wine" in line)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steam-api", type=Path, help="An installed game's own steam_api64.dll")
    parser.add_argument("--app-id", type=int, default=480)
    parser.add_argument("--only", choices=["graphics", "steam", "all"], default="all")
    args = parser.parse_args()
    if args.only in ("all", "steam") and not args.steam_api:
        parser.error("--steam-api is required when testing Steam; use --only graphics otherwise")
    if not 0 < args.app_id <= 0xffffffff:
        parser.error("--app-id must be a positive 32-bit AppID")
    runner = WORK / "runner"
    bridge = WORK / "upstream/build/bridge"
    probe = WORK / "probe.exe"
    acceptance = WORK / "acceptance"
    acceptance.mkdir(exist_ok=True)
    prefix = acceptance / "pfx"
    prefix.mkdir(exist_ok=True)
    for required in [runner / "runner.json", probe, runner / "bin/wine", runner / "bin/wineserver"]:
        if not required.is_file():
            parser.error(f"Missing {required}")
    manifest = json.loads((runner / "runner.json").read_text())
    assert manifest["kind"] == "selfbuilt"
    assert prefix.resolve().is_relative_to(WORK.resolve())
    assert runner.resolve().is_relative_to(WORK.resolve())
    # An allowlist keeps API tokens and unrelated tool/Steam settings out of Wine.
    env = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL",
                                      "__CF_USER_TEXT_ENCODING") if k in os.environ}
    env.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", WINEPREFIX=str(prefix),
               WINELOADER=str(runner / "lib/wine/x86_64-unix/wine"),
               WINESERVER=str(runner / "bin/wineserver"), CX_ROOT=str(runner),
               CX_HOME=str(acceptance / "cx-home"), WINEMSYNC="1", WINEDEBUG="-all",
               WINEDLLPATH=f"{runner}/lib/wine/x86_64-windows:{runner}/lib/wine/x86_64-unix",
               WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml=")
    report = {"runner": manifest, "scope": "isolated runner and read-only native Steam API; no Steam UI installation",
              "cases": [], "liveConfigurationChanged": None}
    output = acceptance / ("results-" + args.only + ".json")

    def save():
        output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    def stop():
        subprocess.run([env["WINESERVER"], "-k"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        subprocess.run([env["WINESERVER"], "-w"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)

    def run(name, command, settings=None, timeout=90, expected=None):
        child_env = env | (settings or {})
        result_file = acceptance / (name + ".result.txt")
        result_file.unlink(missing_ok=True)
        child_env["FLUENT_PROBE_RESULT"] = windows(result_file)
        paths = set()
        log = acceptance / (name + ".log")
        start = time.monotonic()
        with log.open("w") as stream:
            child = subprocess.Popen(command, env=child_env, cwd=acceptance,
                                     stdout=stream, stderr=subprocess.STDOUT)
            timed_out = False
            try:
                while child.poll() is None:
                    paths.update(loaded_files(child.pid))
                    if time.monotonic() - start > timeout:
                        timed_out = True
                        break
                    time.sleep(1)
            finally:
                if child.poll() is None:
                    stop()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                child.wait()
        probe_output = result_file.read_text(errors="replace") if result_file.exists() else ""
        text = log.read_text(errors="replace") + probe_output
        forbidden = sorted(p for p in paths if "/CrossOver.app/" in p or "/NotProton.app/" in p
                           or "/notproton/runners/crossover-" in p)
        required = []
        if name.startswith("dxmt-"):
            required = [str(runner / "lib/wine/x86_64-unix/winemetal.so")]
        elif name.startswith("d3dmetal-"):
            required = [str(runner / "lib/external/libd3dshared.dylib")]
        elif name == "steam-api":
            required = [str(runner / "lib/wine/x86_64-unix/lsteamclient.so"),
                        str(Path.home() / "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib")]
        required_observed = all(p in paths for p in required)
        case = dict(name=name, returncode=child.returncode, timeout=timed_out,
                    seconds=round(time.monotonic() - start, 2), loadedFiles=sorted(paths),
                    forbiddenDependencies=forbidden, log=str(log.relative_to(ROOT)),
                    probeOutput=probe_output.strip(),
                    requiredDependenciesObserved=required_observed,
                    passed=child.returncode == 0 and not timed_out and not forbidden and required_observed
                    and (expected is None or expected in text))
        report["cases"].append(case)
        save()
        print(f"{name}: {'PASS' if case['passed'] else 'FAIL'}", flush=True)
        stop()
        return case["passed"]

    try:
        if not run("wineboot", [env["WINELOADER"], "wineboot", "--init"], timeout=180):
            return 1
        # Wine maps user Documents/Desktop to the real Mac by default. Make disposable
        # directories before any game is tested; keep drive mappings needed to read probes.
        users = prefix / "drive_c/users"
        for link in users.rglob("*"):
            if link.is_symlink() and not link.resolve().is_relative_to(prefix.resolve()):
                link.unlink()
                link.mkdir()
        if args.only in ("all", "graphics"):
            for backend, api in [("dxmt", "11"), ("d3dmetal", "11"), ("d3dmetal", "12")]:
                settings = dict(WINEDLLPATH_PREPEND=str(runner / "lib/renderers" / backend),
                                CX_ACTIVE_GRAPHICS_BACKEND=backend)
                if backend == "d3dmetal":
                    settings["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = str(runner / "lib/external/libd3dshared.dylib")
                run(f"{backend}-d3d{api}", [env["WINELOADER"], str(probe), api],
                    settings, expected="PASS")
        if args.only in ("all", "steam") and args.steam_api:
            assert args.steam_api.is_file() and args.app_id > 0
            dest = prefix / "drive_c/Program Files (x86)/Steam"
            dest.mkdir(parents=True, exist_ok=True)
            for name in ("steamclient.dll", "steamclient64.dll", "tier0_s64.dll", "vstdlib_s64.dll"):
                shutil.copy2(bridge / name, dest / name)
            shutil.copy2(runner / "share/steamplay/steam.exe", dest / "steam.exe")
            shutil.copy2(runner / "lib/wine/x86_64-windows/lsteamclient.dll", dest / "lsteamclient.dll")
            shutil.copy2(runner / "lib/wine/x86_64-unix/lsteamclient.so", dest / "lsteamclient.so")
            shutil.copy2(runner / "lib/wine/i386-windows/lsteamclient.dll",
                         prefix / "drive_c/windows/syswow64/lsteamclient.dll")
            native = Path.home() / "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
            settings = dict(SteamAppId=str(args.app_id), SteamGameId=str(args.app_id),
                            STEAM_COMPAT_CLIENT_INSTALL_PATH=str(native),
                            STEAM_COMPAT_DATA_PATH=str(acceptance),
                            WINEDLLPATH=f"{dest}:{env['WINEDLLPATH']}",
                            WINEDLLOVERRIDES=env["WINEDLLOVERRIDES"] + ";steamclient=n;steamclient64=n;lsteamclient=b")
            run("steam-api", [env["WINELOADER"], str(dest / "steam.exe"), windows(probe),
                              "steam", windows(args.steam_api), str(args.app_id)],
                settings, expected="PASS (read-only)")
    finally:
        stop()
        baseline_path = WORK / "live-baseline.json"
        if baseline_path.exists():
            baseline = json.loads(baseline_path.read_text())
            changed = []
            for name, expected in baseline.items():
                path = Path(name)
                actual = hashlib.file_digest(path.open("rb"), "sha256").hexdigest() if path.is_file() else None
                if actual != expected:
                    changed.append(name)
            report["liveConfigurationChanged"] = changed
        save()
    return 0 if all(case["passed"] for case in report["cases"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
