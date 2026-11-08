#!/usr/bin/env python3
"""Real ARM64 Steam ABI tests in independent processes; no Steam IPC or game writes."""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

args = argparse.ArgumentParser()
args.add_argument("--steam-client", type=Path, required=True)
args.add_argument("--manifest", type=Path, required=True, help="621_9044256803759256265.manifest")
options = args.parse_args()
project = Path(__file__).resolve().parents[1]
probe = project / "work/pins-build/FluentManifestProbe"
client = options.steam_client.resolve()
with tempfile.TemporaryDirectory(prefix="FluentManifestTest-") as temporary:
    root = Path(temporary)
    subprocess.run([str(probe), str(client), str(options.manifest.resolve()), str(root / "case")], check=True, timeout=45)
    subprocess.run([str(probe), "--exit-installed", str(client), str(root / "normal-exit")], check=True, timeout=45)
    assert "manifest pin hook removed" in (root / "normal-exit/pins.log").read_text()
    print("PASS: normal process exit removes hooks before Dobby registry destruction")
    altered = root / "changed-build"
    altered.mkdir()
    target = altered / "steamclient.dylib"
    subprocess.run(["lipo", str(client), "-thin", "arm64", "-output", str(target)], check=True)
    content = bytearray(target.read_bytes())
    position = 32
    changed = False
    for _ in range(struct.unpack_from("<I", content, 16)[0]):
        command, length = struct.unpack_from("<II", content, position)
        if command == 27:
            content[position + 8] ^= 1
            changed = True
        position += length
    assert changed
    target.write_bytes(content)
    subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True, capture_output=True)
    for dependency in client.parent.glob("*.dylib"):
        if dependency.name != "steamclient.dylib":
            (altered / dependency.name).symlink_to(dependency)
    environment = os.environ.copy()
    environment["FLUENT_PINS_STATUS"] = str(root / "rejection.log")
    subprocess.run([str(probe), "--reject-build", str(target)], env=environment, check=True, timeout=45)
print("PASS: test roots removed; original Steam binary, configuration, account and saves unchanged")
