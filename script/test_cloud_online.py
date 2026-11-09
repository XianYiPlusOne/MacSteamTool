#!/usr/bin/env python3
"""Real macOS cloud providers against disposable HTTP servers, never user saves.

Two separate client roots simulate a clean second device. These are protocol
integration tests, not claims of a real external account or physical-device QA.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, unquote, quote, parse_qs
from xml.sax.saxutils import escape
import argparse, base64, hashlib, hmac, json, os, re, ssl, subprocess, tempfile, threading
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--build-dir', type=Path, default=ROOT / 'work/cloud-online-build')
parser.add_argument('--case', help='Run one provider/auth case, e.g. webdav/digest')
args = parser.parse_args()
CLI = args.build_dir.resolve() / 'FluentCloudCLI'
PROBE = args.build_dir.resolve() / 'FluentCloudOnlineProbe'
ACCOUNT, APP = '12345', '900001'  # synthetic fixture IDs, no installed game
USER, PASSWORD, BEARER = 'fixture-user', 'fixture-password', 'fixture-bearer'
ACCESS, SECRET = 'fixture-access', 'fixture-secret'


class State:
    def __init__(self, kind, auth='basic'):
        self.kind, self.auth = kind, auth
        self.files, self.dirs = {}, {'/', '/dav/', '/dav/CloudRedirect/'}
        self.requests = []
        self.mode = ''
        self.redirect = ''
        self.lock = threading.Lock()
        self.race = None
        self.race_waiters = 0
        self.conflicts = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Never log authentication headers or payloads.

    def reply(self, status, body=b'', headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
        self.close_connection = True

    def authorized(self, body):
        state = self.server.state
        value = self.headers.get('Authorization', '')
        if state.kind == 's3':
            try:
                parts = dict(item.strip().split('=', 1) for item in value.removeprefix('AWS4-HMAC-SHA256 ').split(','))
                access, scope = parts['Credential'].split('/', 1)
                date, region, service, terminal = scope.split('/')
                signed = parts['SignedHeaders'].split(';')
                canonical_headers = ''.join(name + ':' + ' '.join(self.headers[name].split()) + '\n' for name in signed)
                parsed = urlsplit(self.path)
                canonical = '\n'.join([self.command, parsed.path, parsed.query, canonical_headers, parts['SignedHeaders'], self.headers['x-amz-content-sha256']])
                string = '\n'.join(['AWS4-HMAC-SHA256', self.headers['x-amz-date'], scope, hashlib.sha256(canonical.encode()).hexdigest()])
                key = ('AWS4' + SECRET).encode()
                for item in [date, region, service, terminal]:
                    key = hmac.new(key, item.encode(), hashlib.sha256).digest()
                valid = access == ACCESS and hmac.compare_digest(hmac.new(key, string.encode(), hashlib.sha256).hexdigest(), parts['Signature'])
                payload_hash = self.headers['x-amz-content-sha256']
                return valid and (payload_hash == 'UNSIGNED-PAYLOAD' or payload_hash == hashlib.sha256(body).hexdigest())
            except (KeyError, ValueError, TypeError, AttributeError):
                return False
        if state.auth == 'basic':
            return value == 'Basic ' + base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()
        if state.auth == 'bearer':
            return value == 'Bearer ' + BEARER
        if state.auth == 'digest':
            if not value.startswith('Digest '):
                return False
            fields = {key: quoted or bare for key, quoted, bare in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]+))', value[7:])}
            md5 = lambda text: hashlib.md5(text.encode()).hexdigest()
            expected = md5(':'.join([md5(f'{USER}:fixture:{PASSWORD}'), 'fixture-nonce', fields.get('nc', ''), fields.get('cnonce', ''), 'auth', md5(f'{self.command}:{fields.get("uri", "")}')]))
            return fields.get('username') == USER and fields.get('uri') == self.path and hmac.compare_digest(fields.get('response', ''), expected)
        return state.auth == 'none'

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        state = self.server.state
        parsed = urlsplit(self.path)
        path = unquote(parsed.path)
        state.requests.append((self.command, path))
        if not self.authorized(body):
            challenge = 'Digest realm="fixture", nonce="fixture-nonce", algorithm=MD5, qop="auth"' if state.auth == 'digest' else 'Basic realm="fixture"'
            return self.reply(401, headers={'WWW-Authenticate': challenge})
        if state.mode == 'redirect':
            return self.reply(307, headers={'Location': state.redirect})
        if self.command == 'PUT' and state.mode == 'read-only':
            return self.reply(403)
        if self.command == 'DELETE' and state.mode == 'delete-denied':
            return self.reply(403)
        if state.kind == 's3':
            return self.s3(path, parsed, body)
        if self.command == 'OPTIONS':
            return self.reply(200, headers={'DAV': '1', 'Allow': 'OPTIONS, HEAD, GET, PUT, DELETE, PROPFIND, MKCOL'})
        if self.command == 'MKCOL':
            directory = path.rstrip('/') + '/'
            if directory in state.dirs:
                return self.reply(405)
            parent = directory.rstrip('/').rsplit('/', 1)[0] + '/'
            if parent not in state.dirs:
                return self.reply(409)
            state.dirs.add(directory)
            return self.reply(201)
        if self.command == 'PROPFIND':
            if state.mode == 'list-denied':
                return self.reply(403)
            directory = path.rstrip('/') + '/'
            if directory not in state.dirs and path not in state.files:
                return self.reply(404)
            entries = [(directory, True, 0)] if directory in state.dirs else [(path, False, len(state.files[path]))]
            if self.headers.get('Depth') != '0' and directory in state.dirs:
                for item in sorted(state.dirs):
                    if item != directory and item.startswith(directory) and '/' not in item[len(directory):].rstrip('/'):
                        entries.append((item, True, 0))
                for item, data in sorted(state.files.items()):
                    if item.startswith(directory) and '/' not in item[len(directory):]:
                        entries.append((item, False, len(data)))
            responses = []
            for item, is_dir, size in entries:
                responses.append(f'<D:response><D:href>{escape(quote(item))}</D:href><D:propstat><D:prop><D:resourcetype>{"<D:collection/>" if is_dir else ""}</D:resourcetype><D:getcontentlength>{size}</D:getcontentlength><D:getlastmodified>Sun, 08 Nov 2026 00:00:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>')
            return self.reply(207, '<D:multistatus xmlns:D="DAV:">' + ''.join(responses) + '</D:multistatus>', {'Content-Type': 'application/xml'})
        return self.object_request(path, body, require_parent=True)

    def object_request(self, path, body, require_parent=False):
        state = self.server.state
        if self.command == 'PUT':
            if require_parent and path.rsplit('/', 1)[0] + '/' not in state.dirs:
                return self.reply(409)
            barrier = None
            if path.endswith('/12345/0/stats.json') and state.race:
                value = json.loads(body).get('900004', {})
                bits = sum(block['bits'] for block in value.get('achievements', []))
                with state.lock:
                    if bits in (1, 2) and state.race_waiters < 2:
                        state.race_waiters += 1
                        barrier = state.race
            if barrier:
                barrier.wait(timeout=20)  # Both clients have already read the same version.
            with state.lock:
                if path.endswith('/12345/0/stats.json') and state.mode in ('cas-busy', 'cas-once-409'):
                    state.conflicts += 1
                    status = 409 if state.mode == 'cas-once-409' else 412
                    if status == 409: state.mode = ''
                    return self.reply(status)
                current = state.files.get(path)
                etag = '"' + hashlib.sha256(current).hexdigest() + '"' if current is not None else None
                if ((self.headers.get('If-None-Match') == '*' and current is not None) or
                    (self.headers.get('If-Match') and self.headers['If-Match'] != etag)):
                    state.conflicts += 1
                    return self.reply(412)
                state.files[path] = body
            return self.reply(200 if state.kind == 's3' else 201)
        if self.command == 'DELETE':
            state.files.pop(path, None)
            return self.reply(204)
        if self.command in ('GET', 'HEAD'):
            if path not in state.files:
                return self.reply(404)
            data = state.files[path]
            if self.command == 'GET' and (state.mode == 'corrupt' or (state.mode == 'corrupt-blob' and '/blobs/' in path)):
                data += b'corrupt'
            headers = {'ETag': '"' + hashlib.sha256(data).hexdigest() + '"'}
            if path.endswith('/12345/0/stats.json'):
                if state.mode == 'no-etag': headers = {}
                if state.mode == 'weak-etag': headers['ETag'] = 'W/' + headers['ETag']
            return self.reply(200, data, headers)
        return self.reply(405)

    def s3(self, path, parsed, body):
        query = parse_qs(parsed.query, keep_blank_values=True)
        if 'versioning' in query:
            return self.reply(200, '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"/>')
        if 'list-type' in query:
            if self.server.state.mode == 'list-denied':
                return self.reply(403)
            prefix = query.get('prefix', [''])[0]
            contents = ''.join(f'<Contents><Key>{escape(key.removeprefix("/bucket/"))}</Key><Size>{len(data)}</Size><LastModified>2026-11-08T00:00:00.000Z</LastModified></Contents>' for key, data in sorted(self.server.state.files.items()) if key.startswith('/bucket/' + prefix))
            return self.reply(200, '<ListBucketResult><IsTruncated>false</IsTruncated>' + contents + '</ListBucketResult>')
        return self.object_request(path, body)

    do_GET = do_HEAD = do_PUT = do_DELETE = do_PROPFIND = do_MKCOL = do_OPTIONS = handle_request


def client(root, provider, fields, destination):
    cfg = root / 'CloudRedirect'
    cfg.mkdir(parents=True)
    credential = cfg / f'{provider}_credentials.json'
    credential.write_text(json.dumps(fields))
    credential.chmod(0o600)
    (cfg / '.fluent-cloud-online-fixture').touch()
    (cfg / 'config.json').write_text(json.dumps({'enabled': False, 'provider': 'folder', 'token_paths': {provider: str(credential), 'folder': str(destination)}}))
    return dict(os.environ, FLUENT_CLOUD_ROOT=str(root), FLUENT_CLOUD_STEAM=str(root / 'No-Steam'))


def run(env, *arguments, expected=0):
    result = subprocess.run([str(CLI), *arguments], env=env, capture_output=True, text=True, timeout=100)
    assert result.returncode == expected, (arguments, result.returncode, result.stdout[-1500:])
    return json.loads(result.stdout.splitlines()[-1])


def scenario(base, provider, auth='basic', tls=False):
    state = State('s3' if provider in ('s3', 'r2') else 'webdav', 'digest' if auth == 'auto' else auth)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.state = state
    cert = None
    if tls:
        cert, key, conf = base / 'certificate.pem', base / 'key.pem', base / 'certificate.conf'
        conf.write_text('[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=localhost\n[v3]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n')
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(conf), '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f'{"https" if tls else "http"}://127.0.0.1:{server.server_port}'
    fields = {'url': endpoint + '/dav', 'username': USER, 'password': PASSWORD, 'bearer_token': BEARER, 'auth': auth, 'timeout_sec': 5}
    if state.kind == 's3':
        fields = {'endpoint': endpoint, 'region': 'us-east-1', 'bucket': 'bucket', 'access_key_id': ACCESS, 'secret_access_key': SECRET, 'sign_payload': True, 'account_id': 'a' * 32}
    if cert:
        fields['ca_cert_path'] = str(cert)
    source, restored = base / 'original', base / 'restored'
    payloads = {f'{ACCOUNT}/{APP}/blobs/中文 save.bin': bytes(range(256)) * 33, f'{ACCOUNT}/{APP}/blobs/empty.bin': b'', f'{ACCOUNT}/{APP}/manifest.json': b'{"fixture":"isolated"}', '54321/900002/blobs/untouched.bin': b'other-account'}
    for name, data in payloads.items():
        path = source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    a = client(base / 'device-a', provider, fields, source)
    b = client(base / 'device-b', provider, fields, restored)
    config_before = (base / 'device-a/CloudRedirect/config.json').read_bytes()
    try:
        proof = run(a, 'probe-provider', provider)
        assert all(proof[key] for key in ('success', 'uploaded', 'downloaded', 'verified', 'cleaned')), proof
        assert proof['bytes'] == 4096 and len(proof['sha256']) == 64
        assert not state.files, 'connection test left an object behind'
        result = run(a, 'migrate', 'folder', provider)
        assert result['migrated'] == len(payloads), result
        inventory = run(b, 'list-remote-apps', provider, ACCOUNT)
        assert inventory['apps'] == [{'app_id': APP, 'file_count': 3, 'total_size': sum(len(v) for k, v in payloads.items() if k.startswith(ACCOUNT + '/'))}], inventory
        result = run(b, 'migrate', provider, 'folder', ACCOUNT)
        assert result['migrated'] == 3, result
        for name, data in payloads.items():
            assert (source / name).read_bytes() == data
            if name.startswith(ACCOUNT + '/'):
                assert (restored / name).read_bytes() == data
            else:
                assert not (restored / name).exists(), 'copied an unselected account'
        assert run(b, 'migrate', provider, 'folder', ACCOUNT)['skipped'] == 3
        conflict = restored / f'{ACCOUNT}/{APP}/manifest.json'
        conflict.write_bytes(b'preserve-existing-progress')
        assert run(b, 'migrate', provider, 'folder', ACCOUNT, expected=1)['failed'] == 1
        assert conflict.read_bytes() == b'preserve-existing-progress'
        original_remote = dict(state.files)
        state.mode = 'read-only'
        failure = run(a, 'probe-provider', provider, expected=1)
        assert not failure['uploaded'] and failure['cleaned'], failure
        state.mode = 'corrupt'
        failure = run(a, 'probe-provider', provider, expected=1)
        assert failure['uploaded'] and not failure['verified'] and failure['cleaned'], failure
        state.mode = 'delete-denied'
        failure = run(a, 'probe-provider', provider, expected=1)
        assert failure['verified'] and not failure['cleaned'], failure
        for path in list(state.files):
            if 'fluent-connection-test-' in path:
                del state.files[path]  # fixture teardown only, not a production cleanup fallback
        state.mode = 'list-denied'
        assert not run(b, 'list-remote-apps', provider, ACCOUNT, expected=1)['success']
        assert state.files == original_remote, 'failure probes changed game objects'
        state.mode = ''
        wrong = dict(fields)
        wrong['secret_access_key' if state.kind == 's3' else 'bearer_token' if auth == 'bearer' else 'password'] = 'invalid-fixture'
        bad = client(base / 'bad-client', provider, wrong, base / 'bad-destination')
        assert not run(bad, 'probe-provider', provider, expected=1)['success']
        if tls:
            untrusted = dict(fields)
            del untrusted['ca_cert_path']
            untrusted_client = client(base / 'untrusted-ca', provider, untrusted, base / 'untrusted-destination')
            assert not run(untrusted_client, 'probe-provider', provider, expected=1)['success'], 'untrusted TLS certificate was accepted'
        if provider == 'webdav' and auth == 'basic' and not tls:
            sink = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            sink.state = State('webdav', 'none')
            sink_thread = threading.Thread(target=sink.serve_forever, daemon=True)
            sink_thread.start()
            try:
                state.mode = 'redirect'
                state.redirect = f'http://127.0.0.1:{sink.server_port}/dav'
                assert not run(a, 'probe-provider', provider, expected=1)['success']
                assert not sink.state.requests, 'cross-origin redirect leaked a request'
            finally:
                sink.shutdown(); sink.server_close(); sink_thread.join(timeout=2)
                state.mode = ''
        assert (base / 'device-a/CloudRedirect/config.json').read_bytes() == config_before
        assert all((source / name).read_bytes() == data for name, data in payloads.items())
        for mode in ('upload', 'download', 'reject-corrupt'):
            state.mode = 'corrupt-blob' if mode == 'reject-corrupt' else ''
            command = [str(PROBE), provider, str(base / f'device-a/CloudRedirect/{provider}_credentials.json'), str(base / f'rpc-{mode}'), mode]
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired as error:
                output = (error.stdout or b'') + (error.stderr or b'')
                raise AssertionError((provider, mode, 'RPC timeout', state.requests[-20:], output[-8000:].decode(errors='replace'))) from None
            assert result.returncode == 0, (provider, mode, result.stderr[-2500:], result.stdout[-1000:])
            assert 'PASS:' in result.stdout
            assert 'WriteFileNoIncrement failed' not in result.stdout + result.stderr
        state.mode = ''
        def stats(mode, suffix=None):
            command = [str(PROBE), provider, str(base / f'device-a/CloudRedirect/{provider}_credentials.json'), str(base / ('rpc-' + (suffix or mode))), mode]
            result = subprocess.run(command, capture_output=True, text=True, timeout=100)
            assert result.returncode == 0, (provider, mode, result.stdout[-2000:], result.stderr[-2000:])
        stats('stats-a'); stats('stats-b'); stats('stats-a', 'stats-a-repeat'); stats('stats-verify')
        before_offline = dict(state.files)
        state.mode = 'read-only'
        stats('stats-offline')
        assert state.files == before_offline, 'failed write changed remote statistics'
        state.mode = ''
        stats('stats-retry', 'stats-offline')
        stats('stats-verify-retry')
        stats('stats-reset'); stats('stats-verify-reset')
        stale = base / 'rpc-stats-stale'
        stale_stats = stale / f'CloudRedirect/stats/{ACCOUNT}'
        stale_stats.mkdir(parents=True)
        (stale / '.stats-offline-fixture').touch()
        (stale_stats / '900004.json').write_bytes((base / f'rpc-stats-a/CloudRedirect/stats/{ACCOUNT}/900004.json').read_bytes())
        (stale_stats / '900004.json.pending').write_text('pending')
        # A disabled app and another account must not join the recovery scope.
        for foreign in [stale_stats / '900005.json', stale / 'CloudRedirect/stats/54321/900004.json']:
            foreign.parent.mkdir(parents=True, exist_ok=True)
            foreign.write_text('{"stats":[],"achievements":[],"playtime":{}}')
            foreign.with_name(foreign.name + '.pending').write_text('pending')
        stats('stats-retry', 'stats-stale'); stats('stats-verify-reset', 'stats-reset-after-stale')
        assert (stale_stats / '900005.json.pending').exists()
        assert (stale / 'CloudRedirect/stats/54321/900004.json.pending').exists()
        stats_blob = next(value for name, value in state.files.items() if name.endswith('/12345/0/stats.json'))
        assert set(json.loads(stats_blob)) == {'900004'}, 'recovery uploaded an out-of-scope app'
        print(f'PASS: {provider}/{auth}: independent-client achievement/stat union, platform-time merge, idempotency, failed-upload restart recovery, durable reset and account/app scope.')
        for failure in ('no-etag', 'weak-etag', 'cas-busy'):
            stats('stats-reset', 'reset-' + failure)
            remote_before = dict(state.files)
            state.mode = failure
            stats('stats-offline', 'pending-' + failure)
            assert state.files == remote_before, 'unsafe write despite missing validator or exhausted conflicts'
            state.mode = ''
            stats('stats-retry', 'pending-' + failure)
            recovered = json.loads(next(value for name, value in state.files.items() if name.endswith('/12345/0/stats.json')))['900004']
            assert recovered['achievements'][0]['bits'] == 4
        state.mode = 'cas-once-409'
        stats('stats-concurrent-a', '409-retry')
        assert state.mode == '', '409 retry was not exercised'
        print(f'PASS: {provider}/{auth}: missing/weak ETag and exhausted conflicts preserve pending progress; later recovery succeeds.')
        # Force both writers to read the same base before either can commit.
        # Test both object creation and replacement, then read with a fresh client.
        stats_key = next(name for name in state.files if name.endswith('/12345/0/stats.json'))
        for existing in (False, True):
            if existing:
                stats('stats-reset', 'race-reset')
            else:
                del state.files[stats_key]
            state.race = threading.Barrier(2); state.race_waiters = 0
            conflicts_before = state.conflicts
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(stats, 'stats-concurrent-' + who, f'race-{existing}-{who}') for who in ('a', 'b')]
                for future in futures: future.result()
            state.race = None
            stats('stats-verify-concurrent', f'race-{existing}-verify')
            assert state.race_waiters == 2, 'concurrent write barrier was not reached'
            assert state.conflicts > conflicts_before, 'no conditional conflict was exercised'
        print(f'PASS: {provider}/{auth}: simultaneous create/update collide; losing writer re-reads and merges; fresh client sees both achievements and 8 minutes.')
        assert any(method == 'PUT' for method, _ in state.requests)
        assert any(method == 'GET' for method, _ in state.requests)
        print(f'PASS: {provider}/{auth}/{"HTTPS" if tls else "HTTP"}: full save RPC batch/manifest/clean-client restore; authenticated upload, independent-client listing/download, binary/empty/Unicode equality, account scope, conflicts, failed auth/write/read/delete/list; source and config unchanged.')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


with tempfile.TemporaryDirectory(prefix='cloud-online-', dir=ROOT / 'work') as directory:
    root = Path(directory)
    for provider, auth, tls in [('webdav', 'basic', False), ('webdav', 'bearer', False), ('webdav', 'digest', False), ('webdav', 'auto', False), ('webdav', 'basic', True), ('s3', 'basic', False), ('r2', 'basic', False)]:
        if args.case and args.case != f'{provider}/{auth}':
            continue
        folder = root / f'{provider}-{auth}-{tls}'
        folder.mkdir()
        scenario(folder, provider, auth, tls)
    if not args.case or args.case == 'folder':
        folder = root / 'folder-regression'
        folder.mkdir()
        (folder / '.fluent-cloud-online-fixture').touch()
        remote = folder / 'remote'
        remote.mkdir()
        for mode in ('upload', 'download'):
            result = subprocess.run([str(PROBE), 'folder', str(remote), str(folder / mode), mode], capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, (mode, result.stderr[-2000:])
        print('PASS: existing folder backend full save batch, clean-client restoration and repeated worker shutdown remain compatible.')
print('PASS: all cloud tests used disposable clients, synthetic files and loopback servers; Steam and real game saves were not accessed.')
