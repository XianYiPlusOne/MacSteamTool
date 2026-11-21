#!/usr/bin/env python3
"""Prove the regression on the original, then verify patched real C functions."""
from pathlib import Path
import subprocess
import shutil
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / "work/notproton-route-tests"
out.mkdir(parents=True, exist_ok=True)
original = out / "original"
if original.exists(): shutil.rmtree(original)
shutil.copytree(ROOT / "Native/NotProtonCore/dylib", original / "dylib")
# Recreate only the pre-fix regression baseline from our maintained source.
subprocess.run(["git", "apply", "--reverse", str(ROOT / "Native/NotProton/webui-capacity.patch")], cwd=original, check=True)
for label, source, expected in [("before", original, 1),
                                ("after", ROOT / "Native/NotProtonCore", 0)]:
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
