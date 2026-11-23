#!/usr/bin/env python3
"""Build MacSteamTool's CrossOver bridge from repository source and pinned Wine/Valve source.

Build dependencies are developer-only. No upstream app, runner clone or paid
CrossOver installation is used to build these artifacts.
"""
from pathlib import Path
import os
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Native/NotProtonCore"
# Older configured Wine trees and their objects contain absolute source paths.
STAGE = ROOT / "work/crossover-bridge-release"
OUTPUTS = [
    "wine-build-dual/programs/steam.exe/x86_64-windows/steam.exe",
    "wine-build-dual/dlls/lsteamclient/x86_64-windows/lsteamclient.dll",
    "wine-build-dual/dlls/lsteamclient/i386-windows/lsteamclient.dll",
    "wine-build-dual/dlls/lsteamclient/lsteamclient.so",
    "wine-build-arm64/dlls/lsteamclient/lsteamclient.so",
]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inputs():
    return {str(p.relative_to(SOURCE)): digest(p)
            for folder in ["bridge", "lsteamclient", "steam-shim"]
            for p in sorted((SOURCE / folder).rglob("*")) if p.is_file()}

def artifacts():
    return {name: digest(STAGE / "scratch" / name) for name in OUTPUTS}

def tool_path():
    """Return a PATH that works with Homebrew on either Mac architecture."""
    path = os.environ.get("PATH", "")
    brew = shutil.which("brew", path=path)
    if not brew:
        return path
    try:
        prefix = subprocess.check_output([brew, "--prefix"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return path
    return os.pathsep.join([f"{prefix}/bin", f"{prefix}/opt/bison/bin",
                            f"{prefix}/opt/autoconf/bin", path])

def build():
    STAGE.mkdir(parents=True, exist_ok=True)
    key = inputs()
    stamp = STAGE / "fluent-build.json"
    if stamp.exists():
        receipt = json.loads(stamp.read_text())
        try:
            if receipt["inputs"] == key and receipt["outputs"] == artifacts():
                print("CrossOver bridge matches maintained source and artifact hashes")
                return
        except (KeyError, FileNotFoundError):
            pass
    # Build scripts generate assembled source and Wine build trees. Keep those
    # outside the maintained sources and never copy an original app payload.
    subprocess.run(["rsync", "-a", "--exclude=upstream.json", str(SOURCE) + "/", str(STAGE) + "/"], check=True)
    env = dict(os.environ, PATH=tool_path(),
               CROSSCFLAGS="-O2", CX_ROOT=str(STAGE / "no-installed-crossover"),
               WINE_URL="https://github.com/wine-mirror/wine.git")
    subprocess.run(["make", "-C", str(STAGE), "bridge"], env=env, check=True)
    stamp.write_text(json.dumps(dict(inputs=key, outputs=artifacts()), indent=2) + "\n")

if __name__ == "__main__":
    build()
