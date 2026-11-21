#!/usr/bin/env python3
"""Build our maintained Steam integrations. Never reads either upstream app."""
from pathlib import Path
import hashlib
import json
import subprocess
from native_core_validation import validate_macsteam

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/native-integration"
NP = ROOT / "Native/NotProtonCore"

def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)

def build():
    dobby = ROOT / "work/pins-build/dobby/libdobby.a"
    if not dobby.is_file():
        run("bash", ROOT / "script/build_pins.sh")
    run("cmake", "-S", ROOT / "Native/SteamIntegration", "-B", OUT / "arm64",
        "-DCMAKE_BUILD_TYPE=Release", f"-DDOBBY_LIBRARY={dobby}")
    run("cmake", "--build", OUT / "arm64", "-j", "6")
    for name, source in [("macsteam", ROOT / "Native/MacSteam/src"), ("notproton", NP / "dylib")]:
        stub = OUT / f"{name}.x86_64.dylib"
        run("clang", "-arch", "x86_64", "-mmacosx-version-min=15.0", "-dynamiclib",
            "-install_name", f"@rpath/{name}.dylib", source / "stub_x86_64.c", "-o", stub)
        run("lipo", "-create", OUT / "arm64" / f"{name}.dylib", stub, "-output", OUT / f"{name}.dylib")
        run("codesign", "--force", "--sign", "-", OUT / f"{name}.dylib")
    validate_macsteam(OUT / "macsteam.dylib")
    run("make", "-C", NP, "-j6", "overlay-shim", "iconmaker", "appinfo", f"OUT_DIR={OUT}/helpers")
    for name in ["iconmaker", "appinfo"]:
        run("codesign", "--force", "--sign", "-", OUT / "helpers" / name)
    receipt = dict(upstream="692b470e73d0d497ee9e474038efda819a037772", repair="webui-capacity-1",
                   patchSHA256=hashlib.sha256((ROOT / "Native/NotProton/webui-capacity.patch").read_bytes()).hexdigest(),
                   sha256=hashlib.sha256((OUT / "notproton.dylib").read_bytes()).hexdigest())
    (OUT / "fluent-notproton-repair.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Built native Steam integrations entirely from Native/ source")

if __name__ == "__main__":
    build()
