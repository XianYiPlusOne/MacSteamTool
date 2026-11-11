#!/usr/bin/env python3
"""Exercise production upgrade cleanup with unique temporary launchd services only."""
from pathlib import Path
import json, os, plistlib, subprocess, tempfile, uuid

ROOT = Path(__file__).resolve().parents[1]
INSPECT = ROOT / '.build/debug/FluentInspect'
DOMAIN = f'gui/{os.getuid()}'
OLD_LABEL = 'dev.fluentsteam.mac.trainer-agent'

def launchctl(*args):
    return subprocess.run(['/bin/launchctl', *args], capture_output=True, text=True)

with tempfile.TemporaryDirectory(prefix='retirement-fixture-', dir=ROOT / 'work') as temp:
    root = Path(temp); (root / '.fluent-retirement-fixture').touch()
    label = 'dev.fluentsteam.fixture-removal.' + str(uuid.uuid4())
    sibling = 'dev.fluentsteam.fixture-removal.' + str(uuid.uuid4())
    try:
        for name in [label, sibling]:
            file = root / (name + '.plist')
            file.write_bytes(plistlib.dumps({'Label': name, 'ProgramArguments': ['/bin/sleep', '120'], 'RunAtLoad': True}))
            result = launchctl('bootstrap', DOMAIN, str(file)); assert result.returncode == 0, result.stderr
            assert launchctl('print', DOMAIN + '/' + name).returncode == 0
        support = root / 'Library/Application Support/FluentSteamMac'; support.mkdir(parents=True)
        settings = support / 'settings.json'
        settings.write_text(json.dumps({'theme': 'dark', 'futureSetting': {'keep': True}, 'trainers': [{'executable': '/fixture-only.exe'}], 'independentTrainerMonitor': True}))
        plist = root / f'Library/LaunchAgents/{OLD_LABEL}.plist'; plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({'Label': OLD_LABEL}))
        sentinel = support / 'Downloads/tool.exe'; sentinel.parent.mkdir(); sentinel.write_bytes(b'keep-download')
        session = support / ('TrainerSessions/' + str(uuid.uuid4())); session.mkdir(parents=True)
        stop = session / 'stop'
        (session / 'config.json').write_text(json.dumps({'stop': 'Z:' + str(stop).replace('/', '\\')}))
        def exercise():
            result = subprocess.run([str(INSPECT), '--exercise-retired-cleanup', str(root), label], capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (result.stdout, result.stderr)
        exercise()
        assert launchctl('print', DOMAIN + '/' + label).returncode != 0
        assert launchctl('print', DOMAIN + '/' + sibling).returncode == 0
        assert not plist.exists() and stop.exists() and sentinel.read_bytes() == b'keep-download'
        assert json.loads(settings.read_text()) == {'theme': 'dark', 'futureSetting': {'keep': True}}
        exercise()  # idempotent after the service/plist are gone
        assert launchctl('print', DOMAIN + '/' + sibling).returncode == 0
        print('PASS: production cleanup unloaded the unique test launchd service; sibling service and downloaded file preserved; settings migrated, stop marker written and repeat cleanup succeeded. No real login item, game or save was accessed.')
    finally:
        for name in [label, sibling]: launchctl('bootout', DOMAIN + '/' + name)
