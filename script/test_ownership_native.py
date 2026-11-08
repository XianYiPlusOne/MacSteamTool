#!/usr/bin/env python3
"""Build/run just the ownership adapter, leaving the main chat's build untouched."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
work = root / 'work/ownership-side'
work.mkdir(parents=True, exist_ok=True)
binary = work / 'FluentOwnershipProbe'
dobby = root / 'work/cloud-build/dobby/libdobby.a'
assert dobby.is_file(), 'Build the pinned native dependencies first'
subprocess.run(['xcrun', 'clang++', '-std=c++20', '-arch', 'arm64',
    '-mmacosx-version-min=14.0', '-I'+str(root/'Native/CloudRedirect/macos'),
    str(root/'Native/CloudRedirect/macos/ownership_hooks.cpp'),
    str(root/'Native/CloudRedirect/macos/log.cpp'),
    str(root/'Native/CloudRedirect/tests/ownership_probe.cpp'), str(dobby),
    '-o', str(binary)], check=True)
steam = Path.home()/'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib'
mac = Path('/Applications/Steam.app/Contents/MacOS/macsteam.dylib')
with tempfile.TemporaryDirectory(prefix='fixture-', dir=work) as temp:
    result = subprocess.run([str(binary), str(steam), str(mac), str(Path(temp)/'data')],
        capture_output=True, text=True, timeout=30)
    (work/'native-probe.log').write_text(result.stdout+'\n'+result.stderr)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr[-2000:]);raise SystemExit(result.returncode)
