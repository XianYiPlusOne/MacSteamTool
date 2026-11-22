#!/usr/bin/env python3
"""Package only explicit source files and the generated application; exclude user data."""
from pathlib import Path
import hashlib
import plistlib
import json
import argparse
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
out = root / "outputs"
app = out / "MacSteamTool.app"
if not app.is_dir():
    raise SystemExit("Build the app first with script/build_and_run.sh --build")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
build = int(plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"])
app_zip = out / f"MacSteamTool-{version}-arm64.zip"
if app_zip.exists(): app_zip.unlink()
subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(app_zip)], check=True)
source_zip = out / f"MacSteamTool-{version}-source.zip"
allow = ["Package.swift", "Package.resolved", "Sources", "Tests", "Engine", "Native", "script", "Resources", "README.md", "LICENSE", "Licenses", "THIRD-PARTY-NOTICES.md", ".gitignore", ".codex/environments/environment.toml"]
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
lines = [hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name for p in [app_zip, source_zip]]
(out / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
for p in [app_zip, source_zip]: print(f"{p.name}: {p.stat().st_size:,} bytes")

# Signing key remains in private work/ and is never included in either archive.
key = root / "work/update-signing/private-key"
if key.is_file():
    parser = argparse.ArgumentParser(); parser.add_argument("--download-url", default=""); args = parser.parse_args()
    payload = root / "work/update-signing/release-payload.json"
    payload.write_text(json.dumps({"version": version, "build": build, "minimumOS": 14, "architecture": "arm64", "url": args.download_url, "sha256": hashlib.sha256(app_zip.read_bytes()).hexdigest(), "size": app_zip.stat().st_size, "notes": "MacSteamTool branding update. Existing installations keep their data and backups. Local build; not notarized."}, separators=(",", ":")))
    subprocess.run(["swift", str(root / "script/sign_update.swift"), "sign", str(key), str(payload), str(out / "release.json")], check=True)
    print("release.json: signed; empty URL means local import only")
