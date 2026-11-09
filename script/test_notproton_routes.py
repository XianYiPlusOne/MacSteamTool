#!/usr/bin/env python3
"""Prove the regression on the original, then verify patched real C functions."""
from pathlib import Path
import subprocess
import tarfile
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "work/notproton-route-tests"
out.mkdir(parents=True, exist_ok=True)
original = out / "original"
original.mkdir(exist_ok=True)
archive = out / "original.tar"
subprocess.run(["git", "-C", str(ROOT / "work/notproton"), "archive", "-o", str(archive),
                "692b470e73d0d497ee9e474038efda819a037772", "dylib"], check=True)
with tarfile.open(archive) as tar: tar.extractall(original, filter="data")
for label, source, expected in [("before", original, 1),
                                ("after", ROOT / "work/notproton-kernel-source", 0)]:
    exe = out / label
    subprocess.run(["clang", "-std=c17", "-arch", "arm64", "-O0", "-g",
                    "-fsanitize=address,undefined", "-Wno-unused-parameter",
                    "-I" + str(source / "dylib"),
                    str(ROOT / "Native/NotProton/webui_routes_test.c"), "-o", str(exe)], check=True)
    result = subprocess.run([str(exe)], capture_output=True, text=True)
    (out / (label + ".log")).write_text(result.stdout + result.stderr)
    assert result.returncode == expected, (label, result.stdout, result.stderr)
    if label == "before": assert "route 9 OpenPrefixLog rejected" in result.stderr
    print(label + ": " + (result.stdout + result.stderr).strip())
