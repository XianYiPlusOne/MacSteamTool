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
    dobby_arm = ROOT / "work/pins-build/arm64/dobby/libdobby.a"
    dobby_x86 = ROOT / "work/pins-build/x86_64/dobby/libdobby.a"
    if not dobby_arm.is_file() or not dobby_x86.is_file():
        run("bash", ROOT / "script/build_pins.sh")
    for arch, dobby in [("arm64", dobby_arm), ("x86_64", dobby_x86)]:
        run("cmake", "-S", ROOT / "Native/SteamIntegration", "-B", OUT / arch,
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_OSX_ARCHITECTURES={arch}",
            f"-DDOBBY_LIBRARY={dobby}",
            f"-DDOBBY_SOURCE={ROOT / 'work/dobby'}")
        run("cmake", "--build", OUT / arch, "-j", "6")

    for name in ["macsteam", "notproton"]:
        run("lipo", "-create", OUT / "arm64" / f"{name}.dylib",
            OUT / "x86_64" / f"{name}.dylib", "-output", OUT / f"{name}.dylib")
        run("codesign", "--force", "--sign", "-", OUT / f"{name}.dylib")
    validate_macsteam(OUT / "macsteam.dylib", "arm64")
    validate_macsteam(OUT / "macsteam.dylib", "x86_64")
    run("make", "-C", NP, "-j6", "overlay-shim", "iconmaker", "appinfo", f"OUT_DIR={OUT}/helpers")
    for name in ["iconmaker", "appinfo"]:
        run("codesign", "--force", "--sign", "-", OUT / "helpers" / name)
    receipt = dict(upstream="692b470e73d0d497ee9e474038efda819a037772", repair="webui-capacity-1",
                   patchSHA256=hashlib.sha256((ROOT / "Native/NotProton/webui-capacity.patch").read_bytes()).hexdigest(),
                   sha256=hashlib.sha256((OUT / "notproton.dylib").read_bytes()).hexdigest())
    (OUT / "repair-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Built native Steam integrations entirely from Native/ source")

if __name__ == "__main__":
    build()
