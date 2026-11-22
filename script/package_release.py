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
import zipfile

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
        app_zip = staging / f"MacSteamTool-{version}-arm64.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_zip)], check=True)
        app_dmg = staging / f"MacSteamTool-{version}-arm64.dmg"
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
        source_zip = staging / f"MacSteamTool-{version}-source.zip"
        allow = ["Package.swift", "Package.resolved", "Sources", "Tests", "Engine", "Native", "script", "Resources", "README.md", "README.zh-CN.md", "LICENSE", "Licenses", "THIRD-PARTY-NOTICES.md", ".gitignore", ".codex/environments/environment.toml"]
        with zipfile.ZipFile(source_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for entry in allow:
                path = root / entry
                files = sorted(path.rglob("*")) if path.is_dir() else [path]
                for file in files:
                    if file.is_file() and not file.is_symlink() and file.name != ".DS_Store" and not {"__pycache__", "bin", "obj", ".build", ".swiftpm"}.intersection(file.relative_to(root).parts):
                        archive.write(file, "MacSteamTool/" + str(file.relative_to(root)))
        with zipfile.ZipFile(source_zip) as archive:
            assert archive.testzip() is None
            assert not any("/work/" in n or "/.build/" in n or "/outputs/" in n for n in archive.namelist())
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
            payload.write_text(json.dumps({"version": version, "build": build, "minimumOS": 14, "architecture": "arm64", "url": args.download_url, "sha256": hashlib.sha256(app_zip.read_bytes()).hexdigest(), "size": app_zip.stat().st_size, "notes": "The guide installs the official Valve client and automatically advances to the Wine or CrossOver choice. Local build; not notarized."}, separators=(",", ":")))
            subprocess.run(["swift", str(root / "script/sign_update.swift"), "sign", str(key), str(payload), str(staging / "release.json")], check=True)
            publish.append(staging / "release.json")
            print("release.json: signed; empty URL means local import only")

        for file in publish:
            file.replace(out / file.name)
finally:
    os.close(lock)
