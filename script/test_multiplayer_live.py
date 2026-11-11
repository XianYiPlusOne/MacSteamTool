#!/usr/bin/env python3
"""Live AppID 480 lobby and UDP diagnostics through a fresh disposable prefix.

Uses an existing genuine game's SDK DLL as a library; never launches its game.
Example:
  python3 script/test_multiplayer_live.py --sdk '/path/to/steam_api64.dll'

Steam must already be signed in. The test creates and leaves a private one-user
lobby on Steam's servers. It does not prove two-player, NAT, or game compatibility.
No installed extension, game settings, saves, or real prefixes are modified.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', type=Path, required=True)
args = parser.parse_args()
sdk = args.sdk.resolve(strict=True)
inspect = ROOT / '.build/debug/FluentInspect'
template = (ROOT / 'work/notproton-test/compatdata/480/pfx').resolve(strict=True)
python = ROOT / 'work/windows-test-runtime/python.exe'
assert template.is_relative_to(ROOT / 'work') and (template / 'user.reg').is_file()
assert inspect.is_file() and python.is_file()
evidence = ROOT / 'work/multiplayer-live' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
evidence.mkdir(parents=True, mode=0o700)
win = lambda path: 'Z:' + str(path).replace('/', '\\')
before = hashlib.sha256(sdk.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='multiplayer-live-', dir=ROOT / 'work') as directory:
    temporary = Path(directory)
    steam = temporary / 'Steam'
    compat = steam / 'steamapps/compatdata/480'
    compat.mkdir(parents=True)
    # Clone only a known test prefix. Never kill or mutate a real game prefix.
    subprocess.run(['/bin/cp', '-cR', str(template), str(compat / 'pfx')], check=True)
    for name in ['notproton-build', 'notproton-msync']:
        if (template.parent / name).exists():
            shutil.copy2(template.parent / name, compat / name)
    (steam / 'Steam.AppBundle').symlink_to(Path.home() / 'Library/Application Support/Steam/Steam.AppBundle', target_is_directory=True)
    local_sdk = temporary / 'steam_api64.dll'
    shutil.copy2(sdk, local_sdk)
    plan = json.loads(subprocess.check_output([str(inspect), '--wine-plan', str(steam), '480', str(python)]))
    env = os.environ.copy()
    env.update(plan['environment'])
    env.update(WINEDEBUG='-all,err+steam,err+module,warn+steamclient', SteamAppId='480', SteamGameId='480')
    assert Path(env['WINEPREFIX']).resolve() == (compat / 'pfx').resolve()
    server = env['WINESERVER']
    response = evidence / 'result.json'
    response.touch(mode=0o600)
    # A real game is launched through NotProton's Steam shim, which initializes
    # the prefix's Steam registry and native IPC bridge before spawning the child.
    command = [plan['executable'], r'C:\Program Files (x86)\Steam\steam.exe', win(python), win(ROOT / 'script/probe_multiplayer_windows.py'), win(local_sdk), win(response)]
    try:
        with (evidence / 'probe.log').open('w') as log:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        print((evidence / 'probe.log').read_text(), end='')
        if response.with_suffix('.worker.log').exists():
            print(response.with_suffix('.worker.log').read_text(), end='')
        assert result.returncode == 0, f'Probe exited {result.returncode}: {response}'
        report = json.loads(response.read_text())
        assert report['ok'] and report['lobbyLeft']
    finally:
        subprocess.run([server, '-k'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        subprocess.run([server, '-w'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=25, check=True)
        assert hashlib.sha256(sdk.read_bytes()).hexdigest() == before, 'Source SDK changed'
        print('Evidence:', evidence)
