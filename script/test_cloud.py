#!/usr/bin/env python3
"""Exercise the built macOS cloud CLI only against disposable provider roots."""
from pathlib import Path
import json, os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
cli = root / 'work/cloud-build/FluentCloudCLI'
with tempfile.TemporaryDirectory(prefix='fluent-cloud-', dir=root / 'work') as tmp:
    fixture = Path(tmp)
    config = fixture / 'CloudRedirect'
    src, dst = config / 'storage', fixture / 'remote'
    (src / '1/480/blobs').mkdir(parents=True)
    dst.mkdir()
    contents = {'1/480/blobs/a.bin': bytes(range(256)) * 32,
                '1/480/manifest.json': b'{"test":true}',
                '2/480/empty.bin': b''}
    for name, data in contents.items():
        path = src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (config / 'config.json').write_text(json.dumps({'provider':'local','enabled':False,'apps':[], 'token_paths':{'folder':str(dst)}}))
    env = dict(os.environ, FLUENT_CLOUD_ROOT=str(fixture), FLUENT_CLOUD_STEAM=str(fixture / 'Steam'))
    def run(*args, expected=0):
        result = subprocess.run([str(cli), *args], env=env, capture_output=True, text=True, timeout=40)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr[-3000:])
        return [json.loads(line) for line in result.stdout.splitlines() if line]
    assert run('auth-status','folder')[0]['authenticated']
    result = run('migrate','local','folder')[-1]
    assert result['migrated'] == 3 and result['failed'] == 0, result
    for name, data in contents.items():
        assert (src / name).read_bytes() == data
        assert (dst / name).read_bytes() == data
    again = run('migrate','local','folder')[-1]
    assert again['skipped'] == 3 and again['migrated'] == 0, again
    conflict = dst / '1/480/manifest.json'
    conflict.write_bytes(b'keep-different-destination')
    failed = run('migrate','local','folder',expected=1)[-1]
    assert failed['failed'] == 1 and failed['skipped'] == 2, failed
    assert conflict.read_bytes() == b'keep-different-destination'
    assert (src / '1/480/manifest.json').read_bytes() == contents['1/480/manifest.json']
    print('PASS: isolated cloud CLI migration, binary/empty-file equality, repeat migration, conflict preservation and source immutability.')
