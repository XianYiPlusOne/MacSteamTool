#!/usr/bin/env python3
"""Build universal and architecture-specific MacSteamTool release artifacts."""
from pathlib import Path
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from package_source import write_source_zip

root = Path(__file__).resolve().parents[1]
out = root / "outputs"
app = out / "MacSteamTool.app"
if not app.is_dir():
    raise SystemExit("Build the app first with script/build_and_run.sh --build")


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def verify_bundle(bundle, architecture=None):
    command = ["python3", root / "script/verify_bundled_cores.py", bundle]
    if architecture:
        command += ["--architecture", architecture]
    run(*command)


def thin_macho_tree(bundle, architecture):
    """Thin every host Mach-O in a copied app to one architecture."""
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        parts = path.relative_to(bundle).parts
        # CrossOver's bridge contains separate Wine/Unix target binaries. They
        # are selected by the runner and must remain available in both host
        # architecture packages.
        if "RuntimeBackends" in parts and "bridge" in parts:
            continue
        info = subprocess.run(["lipo", "-info", path], capture_output=True, text=True)
        if info.returncode != 0:
            continue
        text = info.stdout + info.stderr
        if "Architectures in the fat file" in text:
            temporary = path.with_name(path.name + ".thin")
            try:
                run("lipo", "-thin", architecture, path, "-output", temporary)
                shutil.copymode(path, temporary)
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        elif "Non-fat file" not in text:
            raise RuntimeError(f"Unexpected lipo output for {path}: {text.strip()}")
        verify = subprocess.run(["lipo", "-verify_arch", architecture, path],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if verify.returncode != 0:
            raise RuntimeError(f"{path} does not contain {architecture}: {verify.stderr.strip()}")


def reseal_component(folder):
    receipt_path = folder / "component.json"
    receipt = json.loads(receipt_path.read_text())
    receipt["files"] = {
        str(path.relative_to(folder)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(folder.rglob("*"))
        if path.is_file() and path != receipt_path
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")


def prepare_architecture_app(architecture, staging):
    if architecture == "universal":
        return app
    variant_root = staging / f"variant-{architecture}"
    variant_root.mkdir()
    variant = variant_root / "MacSteamTool.app"
    shutil.copytree(app, variant, symlinks=True)
    thin_macho_tree(variant, architecture)
    for relative in (
        "Contents/Resources/RuntimeComponents/macsteam/0.8.2",
        "Contents/Resources/RuntimeComponents/notproton/1.2.3",
        "Contents/Resources/RuntimeBackends/crossover",
    ):
        reseal_component(variant / relative)
    run("codesign", "--force", "--deep", "--sign", "-", variant)
    run("codesign", "--verify", "--deep", "--strict", variant)
    verify_bundle(variant, architecture)
    return variant


def package_variant(version, label, variant, staging):
    app_zip = staging / f"MacSteamTool-{version}-{label}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", variant, app_zip)

    app_dmg = staging / f"MacSteamTool-{version}-{label}.dmg"
    volume = staging / f"volume-{label}"
    volume.mkdir()
    staged_app = volume / variant.name
    run("ditto", variant, staged_app)
    # Retain transparent filesystem compression when copying the app off the image.
    for folder in ("MacOS", "Resources/RuntimeBackends", "Resources/Helpers/ConnectTool"):
        relative = Path("Contents") / folder
        source = variant / relative
        if not source.exists():
            continue
        shutil.rmtree(staged_app / relative)
        run("ditto", "--noclone", "--hfsCompression", source, staged_app / relative)
    run("codesign", "--verify", "--deep", "--strict", staged_app)
    run("hdiutil", "create", "-quiet", "-fs", "HFS+", "-format", "ULMO",
        "-volname", f"MacSteamTool-{label}", "-srcfolder", volume, app_dmg)
    run("hdiutil", "verify", "-quiet", app_dmg)
    return app_zip, app_dmg


def signed_release(root_dir, path, version, build, architecture, archive, download_url, key):
    if not key.is_file():
        return None
    url = download_url.replace("{arch}", architecture)
    payload = root_dir / "work/update-signing" / f"release-payload-{architecture}.json"
    payload.write_text(json.dumps({
        "version": version,
        "build": build,
        "minimumOS": 14,
        "architecture": architecture,
        "url": url,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "size": archive.stat().st_size,
        "notes": f"{architecture} macOS build; local build; not notarized.",
    }, separators=(",", ":")))
    run("swift", root_dir / "script/sign_update.swift", "sign", key, payload, path)
    return path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--download-url", default="",
                    help="HTTPS archive URL; use {arch} for architecture-specific assets")
args = parser.parse_args()

run("codesign", "--verify", "--deep", "--strict", app)
verify_bundle(app)
version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
build = int(plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"])

lock = os.open(out, os.O_RDONLY)
try:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=out) as directory:
        staging = Path(directory)
        variants = {}
        for label in ("universal", "arm64", "x86_64"):
            variants[label] = prepare_architecture_app(label, staging)

        app_artifacts = []
        for label, variant in variants.items():
            app_artifacts.extend(package_variant(version, label, variant, staging))

        source_zip = staging / f"MacSteamTool-{version}-source.zip"
        write_source_zip(root, source_zip)
        artifacts = app_artifacts + [source_zip]
        lines = [hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name
                 for path in artifacts]
        (staging / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")
        for path in artifacts:
            print(f"{path.name}: {path.stat().st_size:,} bytes")

        key = root / "work/update-signing/private-key"
        release_files = []
        for label, archive in zip(("universal", "arm64", "x86_64"),
                                  (app_artifacts[0], app_artifacts[2], app_artifacts[4])):
            release_name = "release.json" if label == "universal" else f"release-{label}.json"
            release_path = staging / release_name
            if signed_release(root, release_path, version, build, label, archive,
                              args.download_url, key):
                release_files.append(release_path)

        publish = artifacts + [staging / "SHA256SUMS.txt"] + release_files
        run("python3", root / "script/verify_release_paths.py", app, *app_artifacts)
        for path in publish:
            path.replace(out / path.name)
        if release_files:
            print("release metadata: signed; empty URL means local import only")
finally:
    os.close(lock)
