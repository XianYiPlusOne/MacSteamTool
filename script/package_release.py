#!/usr/bin/env python3
"""Package only explicit source files and the generated application; exclude user data."""
from pathlib import Path
import hashlib
import fcntl
import os
import plistlib
import json
import argparse
import shutil
import subprocess
import tempfile
from package_source import write_source_zip

root = Path(__file__).resolve().parents[1]
out = root / "outputs"
app = out / "MacSteamTool.app"
if not app.is_dir():
    raise SystemExit("Build the app first with script/build_and_run.sh --build")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
subprocess.run(["python3", str(root / "script/verify_bundled_cores.py"), str(app)], check=True)
version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
build = int(plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"])

lock = os.open(out, os.O_RDONLY)
try:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=out) as directory:
        staging = Path(directory)
        app_zip = staging / f"MacSteamTool-{version}-universal.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_zip)], check=True)
        app_dmg = staging / f"MacSteamTool-{version}-universal.dmg"
        volume = staging / "volume"
        volume.mkdir()
        staged_app = volume / app.name
        subprocess.run(["ditto", app, staged_app], check=True)
        # Retain transparent filesystem compression when copying the app off the image.
        for folder in ("MacOS", "Resources/RuntimeBackends", "Resources/Helpers/ConnectTool"):
            relative = Path("Contents") / folder
            shutil.rmtree(staged_app / relative)
            subprocess.run(["ditto", "--noclone", "--hfsCompression", app / relative, staged_app / relative], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", staged_app], check=True)
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "ULMO",
                        "-volname", app.stem, "-srcfolder", volume, app_dmg], check=True)
        subprocess.run(["hdiutil", "verify", "-quiet", app_dmg], check=True)
        subprocess.run(["python3", root / "script/verify_release_paths.py", app, app_zip, app_dmg], check=True)
        source_zip = staging / f"MacSteamTool-{version}-source.zip"
        write_source_zip(root, source_zip)
        artifacts = [app_zip, app_dmg, source_zip]
        lines = [hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name for p in artifacts]
        (staging / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
        for p in artifacts: print(f"{p.name}: {p.stat().st_size:,} bytes")

        # Signing key remains in private work/ and is never included in either archive.
        publish = artifacts + [staging / "SHA256SUMS.txt"]
        key = root / "work/update-signing/private-key"
        if key.is_file():
            parser = argparse.ArgumentParser(); parser.add_argument("--download-url", default=""); args = parser.parse_args()
            payload = root / "work/update-signing/release-payload.json"
            payload.write_text(json.dumps({"version": version, "build": build, "minimumOS": 14, "architecture": "universal", "url": args.download_url, "sha256": hashlib.sha256(app_zip.read_bytes()).hexdigest(), "size": app_zip.stat().st_size, "notes": "Universal arm64/x86_64 build; local build; not notarized."}, separators=(",", ":")))
            subprocess.run(["swift", str(root / "script/sign_update.swift"), "sign", str(key), str(payload), str(staging / "release.json")], check=True)
            publish.append(staging / "release.json")
            print("release.json: signed; empty URL means local import only")

        for file in publish:
            file.replace(out / file.name)
finally:
    os.close(lock)
