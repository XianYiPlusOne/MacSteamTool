#!/usr/bin/env python3
"""Check the final signed bundle's native cores and their runtime boundary."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import subprocess
from native_core_validation import validate_macsteam
from bundle_connecttool import verify as verify_multiplayer

app = Path(sys.argv[1])
verify_multiplayer(app / 'Contents/Resources/Helpers/ConnectTool')
retired = {
    'steamengine', 'macsteamtoolengine', 'steamkit2.dll', 'steamlessbridge',
    'steamlessbridge.exe', 'dotnet', 'dotnet.exe', 'coreclr.dll', 'libcoreclr.dylib',
    'hostfxr.dll', 'libhostfxr.dylib', 'hostpolicy.dll', 'libhostpolicy.dylib',
    'system.private.corelib.dll',
}
for entry in app.rglob('*'):
    assert entry.name.lower() not in retired, f'Retired helper or .NET runtime in bundle: {entry}'
    if entry.suffix.lower() not in {'.exe', '.dll'} or not entry.is_file():
        continue
    data = entry.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        continue
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe + 26 > len(data) or data[pe:pe+4] != b'PE\0\0':
        continue
    optional = pe + 24
    magic = struct.unpack_from('<H', data, optional)[0]
    if magic not in {0x10b, 0x20b}:
        continue
    directories = optional + (96 if magic == 0x10b else 112)
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    if directories + 15 * 8 <= min(len(data), optional + optional_size):
        count = struct.unpack_from('<I', data, directories - 4)[0]
        if count >= 15:
            clr = struct.unpack_from('<II', data, directories + 14 * 8)
            assert clr == (0, 0), f'Managed PE assembly in bundle: {entry}'
print('PASS: no retired helpers, .NET runtime or managed Windows assemblies')
root = app / 'Contents/Resources/RuntimeComponents'
for provider, version in [('macsteam', '0.8.2'), ('notproton', '1.2.3')]:
    component = root / provider / version
    receipt = json.loads((component / 'component.json').read_text())
    assert receipt['provider'] == provider and receipt['version'] == version
    assert receipt['source'].startswith('MacSteamTool maintained source:'), 'Upstream app payload is not an internal implementation'
    assert not any(p.is_symlink() for p in component.rglob('*')), 'Unexpected symlink'
    actual = {str(p.relative_to(component)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in component.rglob('*') if p.is_file() and p != component / 'component.json'}
    assert actual == receipt['files'], f'{provider}: signed bundle changed component inventory'
    if provider == 'macsteam':
        validate_macsteam(component / 'Resources/macsteam.dylib')
    assert not any(part in {'bridge', 'fonts', 'runners', 'MacOS'} for key in actual for part in Path(key).parts)
    assert not any(Path(key).name in {'run', 'wine', 'wineserver', 'valve-packages.manifest'} for key in actual)
    print(f'PASS: {provider} {version}, {len(actual)} native resource files, complete inventory intact')
assert (app / 'Contents/Helpers/NotProton/MacSteamToolNotProton').is_file()
for arch in ('arm64', 'x86_64'):
    subprocess.run(['lipo', str(app / 'Contents/Helpers/NotProton/MacSteamToolNotProton'),
                    '-verify_arch', arch], check=True)
print('PASS: bundled installer present; core resources contain no external manager or translation backend')
backend = app / 'Contents/Resources/RuntimeBackends/crossover'
receipt = json.loads((backend / 'component.json').read_text())
actual = {str(p.relative_to(backend)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in backend.rglob('*') if p.is_file() and p != backend / 'component.json'}
assert receipt['source'].startswith('MacSteamTool maintained source:') and actual == receipt['files']
assert not any(p.is_symlink() for p in backend.rglob('*'))
assert sum('/bridge/' in name for name in actual) == 5
assert not any(Path(name).name in {'wine', 'wineserver', 'NotProtonApp', 'MacsteamApp'} for name in actual)
print('PASS: source-built CrossOver bridge complete; no paid runtime or external manager included')
