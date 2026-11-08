#!/usr/bin/env python3
"""Exercise cloud hooks against an installed Steam binary, with isolated data only.

No Steam IPC session, user saves, achievements, login or client restart.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--build-dir', type=Path, default=root / 'work/cloud-build')
parser.add_argument('--steam-library', type=Path, default=Path.home() / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib')
args = parser.parse_args()
probe = args.build_dir.resolve() / 'FluentCloudProbe'
with tempfile.TemporaryDirectory(prefix='cloud-native-', dir=root / 'work') as directory:
    for mode in ['folder', 'failed-provider']:
        command = [str(probe), str(args.steam_library.resolve()), str(Path(directory) / mode)]
        if mode == 'failed-provider':
            command.append(mode)
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        lines = (run.stdout + run.stderr).splitlines()
        for line in lines:
            if line.startswith(('PASS:', 'FAIL:')):
                print(line)
        if run.returncode:
            raise SystemExit(f'Isolated cloud probe {mode} failed (exit {run.returncode}); no user data was used.')
print('PASS: automatic cloud scope, restart guard, provider failure, macOS/NotProton paths, real native protobuf and full isolated save transfer.')
