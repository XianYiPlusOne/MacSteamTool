#!/usr/bin/env python3
"""Check the final signed bundle's native cores and their runtime boundary."""
import hashlib
import json
from pathlib import Path
import sys
from native_core_validation import validate_macsteam

app = Path(sys.argv[1])
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
