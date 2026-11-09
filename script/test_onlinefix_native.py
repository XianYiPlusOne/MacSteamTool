#!/usr/bin/env python3
"""Private-process hook checks. Does not connect to Steam or start games."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
client = Path.home() / 'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib'
with tempfile.TemporaryDirectory(prefix='onlinefix-fixture-', dir=root / 'work') as folder:
    fixture = Path(folder)
    (fixture / 'CloudRedirect').mkdir()
    config = fixture / 'config.yaml'
    config.write_text('Apps:\n  - 4348910 # Fixture game\n')
    env = dict(os.environ, FLUENT_CLOUD_ROOT=str(fixture), FLUENT_CLOUD_STEAM=str(fixture / 'Steam'), MACSTEAM_CONFIG=str(config))
    subprocess.run([str(root / 'work/cloud-build/FluentOnlineFixProbe'), str(client)], env=env, check=True, timeout=60)
