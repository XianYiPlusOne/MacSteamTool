#!/usr/bin/env python3
"""Verify the real helper's OAuth callback handling without opening a browser or signing in."""
from pathlib import Path
import json, os, subprocess, tempfile, time
from urllib.parse import urlparse, parse_qs, urlencode
from urllib.request import urlopen
from urllib.error import HTTPError
root = Path(__file__).resolve().parents[1]
engine = root / 'outputs/Fluent Steam Mac.app/Contents/Resources/Helpers/SteamEngine/FluentSteamEngine'
for provider in ('gdrive', 'onedrive'):
    with tempfile.TemporaryDirectory(prefix='fluent-oauth-', dir=root / 'work') as tmp:
        folder = Path(tmp)
        req, out = folder / 'request.json', folder / 'response.json'
        req.write_text(json.dumps({'operation':'cloud-oauth','provider':provider}))
        req.chmod(0o600)
        process = subprocess.Popen([str(engine), str(req), str(out)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            status = Path(str(out) + '.status')
            until = time.monotonic() + 20
            while not status.exists() and time.monotonic() < until and process.poll() is None:
                time.sleep(.1)
            assert status.exists(), f'{provider}: listener not ready'
            auth = urlparse(json.loads(status.read_text())['url'])
            args = parse_qs(auth.query)
            assert auth.scheme == 'https' and args['code_challenge_method'] == ['S256']
            assert len(args['code_challenge'][0]) == 43
            callback = args['redirect_uri'][0]
            assert urlparse(callback).hostname == 'localhost'
            # The callback only listens on IPv4 loopback. No request to the provider.
            callback = callback.replace('localhost', '127.0.0.1')
            try:
                urlopen(callback + '?' + urlencode({'state':'wrong-session','code':'not-a-real-code'}), timeout=5)
                raise AssertionError('wrong state accepted')
            except HTTPError as error:
                assert error.code == 400
            assert process.poll() is None, 'invalid callback ended the active session'
            with urlopen(callback + '?' + urlencode({'state':args['state'][0], 'error':'access_denied'}), timeout=5) as response:
                assert response.status == 200
            assert process.wait(timeout=10) == 1
            result = json.loads(out.read_text())
            assert result['ok'] is False and 'access_denied' in result['error']
            assert out.stat().st_mode & 0o777 == 0o600
            print(f'PASS: {provider} PKCE, loopback callback, invalid-state rejection, cancellation and private output; no login or provider request.')
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
