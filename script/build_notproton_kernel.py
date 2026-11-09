#!/usr/bin/env python3
"""Build the pinned NotProton kernel with Fluent's reviewed source patch.

Never deploys or touches a runner/prefix. The reference checkout stays unchanged.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
REV = "692b470e73d0d497ee9e474038efda819a037772"
source = ROOT / "work/notproton"
stage = ROOT / "work/notproton-kernel-source"
patch = ROOT / "Native/NotProton/webui-capacity.patch"
if not (source / ".git").is_dir():
    subprocess.run(["git", "clone", "https://github.com/NotProtonNot/NotProton.git", str(source)], check=True)
subprocess.run(["git", "-C", str(source), "cat-file", "-e", REV + "^{commit}"], check=True)
archive = ROOT / "work/notproton-kernel-source.tar"
subprocess.run(["git", "-C", str(source), "archive", "--format=tar", "-o", str(archive), REV,
                "Makefile", "dylib", "vendor/cJSON.c", "vendor/cJSON.h", "LICENSE"], check=True)
stage.mkdir(parents=True, exist_ok=True)
with tarfile.open(archive) as tar:
    # All paths are from the fixed trusted commit, with no links accepted.
    for entry in tar.getmembers():
        assert not entry.name.startswith("/") and ".." not in Path(entry.name).parts
        assert entry.isdir() or entry.isfile(), entry.name
    tar.extractall(stage, filter="data")
subprocess.run(["git", "apply", "--check", str(patch)], cwd=stage, check=True)
subprocess.run(["git", "apply", str(patch)], cwd=stage, check=True)
dobby = ROOT / "work/pins-build/dobby/libdobby.a"
if not dobby.is_file():
    subprocess.run(["bash", str(ROOT / "script/build_pins.sh")], check=True)
subprocess.run(["make", "-j6", "dylib", f"DOBBY_LIBS={dobby}"], cwd=stage, check=True)
binary = stage / "out/notproton.dylib"
subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
receipt = dict(upstream=REV, patchSHA256=hashlib.sha256(patch.read_bytes()).hexdigest(),
               sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), repair="webui-capacity-1")
(stage / "out/fluent-notproton-repair.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(binary)
