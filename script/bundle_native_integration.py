#!/usr/bin/env python3
"""Package only Fluent-built integrations, source assets and bridge artifacts."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "work/native-integration"
NP = ROOT / "Native/NotProtonCore"
BRIDGE = ROOT / "work/crossover-bridge-source/scratch"

def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)

def seal(folder, provider, version):
    files = {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(folder.rglob("*")) if p.is_file()}
    receipt = dict(provider=provider, version=version, source="Fluent maintained source: Native/" +
                   ("MacSteam" if provider == "macsteam" else "NotProtonCore"), files=files, root="file:///")
    (folder / "component.json").write_text(json.dumps(receipt, indent=2) + "\n")

def package(resources):
    mac = resources / "RuntimeComponents/macsteam/0.8.2"
    np = resources / "RuntimeComponents/notproton/1.2.3"
    for path in [mac, np, resources / "RuntimeBackends/crossover"]:
        if path.exists():
            raise RuntimeError(f"Packaging output must be empty: {path}")
    copy(BUILD / "macsteam.dylib", mac / "Resources/macsteam.dylib")
    (mac / "Resources/macsteam.dylib.version").write_text("0.8.2\n")
    copy(ROOT / "Native/MacSteam/signatures", mac / "Resources/signatures")
    bundle = np / "NotProtonRuntime.bundle/Contents"
    bundle.mkdir(parents=True)
    (bundle / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier="dev.fluentsteam.integration.resources", CFBundlePackageType="BNDL",
        CFBundleName="Fluent Steam Integration", CFBundleVersion="1.2.3")))
    payload = bundle / "Resources/payload"
    copy(BUILD / "notproton.dylib", payload / "notproton.dylib")
    for name in ["overlay-shim.dylib", "iconmaker", "appinfo"]:
        copy(BUILD / "helpers" / name, payload / name)
    copy(NP / "signatures", payload / "signatures")
    # Stable source revision epoch; avoids spurious prefix/template rebuilds.
    (payload / "build-time").write_text("1794441600\n")
    (payload / "core-version").write_text("1.2.3\n")
    # Backend resources have their own cache and are never deployed by core init.
    backend = resources / "RuntimeBackends/crossover"
    shutil.copytree(np, backend)
    backend_resources = backend / "NotProtonRuntime.bundle/Contents/Resources"
    for source in (NP / "Resources").iterdir():
        copy(source, backend_resources / source.name)
    copy(NP / "dylib/feats/compat_run.sh", backend_resources / "payload/run")
    bridge_outputs = {
        "steam.exe": "wine-build-dual/programs/steam.exe/x86_64-windows/steam.exe",
        "x86_64-windows-lsteamclient.dll": "wine-build-dual/dlls/lsteamclient/x86_64-windows/lsteamclient.dll",
        "i386-windows-lsteamclient.dll": "wine-build-dual/dlls/lsteamclient/i386-windows/lsteamclient.dll",
        "x86_64-unix-lsteamclient.so": "wine-build-dual/dlls/lsteamclient/lsteamclient.so",
        "aarch64-unix-lsteamclient.so": "wine-build-arm64/dlls/lsteamclient/lsteamclient.so",
    }
    for name, relative in bridge_outputs.items():
        copy(BRIDGE / relative, backend_resources / "payload/bridge" / name)
    # Original, unrenamed redistributable fonts, with family licenses. CrossOver
    # also supplies its own Wine fonts. No proprietary Windows font is copied.
    for family in (NP / "fonts").iterdir():
        for font in family.glob("*.ttf"):
            copy(font, backend_resources / "payload/fonts" / font.name)
        for name in ["LICENSE", "license.html", "PROTON_NOTE.md"]:
            if (family / name).is_file():
                copy(family / name, backend_resources / "payload/fonts/licenses" / family.name / name)
    for folder, provider, version in [(mac, "macsteam", "0.8.2"), (np, "notproton", "1.2.3"), (backend, "notproton", "1.2.3")]:
        seal(folder, provider, version)
    print("Packaged Fluent source-built native integrations and CrossOver bridge; no manager app extraction")

if __name__ == "__main__":
    package(Path(sys.argv[1]))
