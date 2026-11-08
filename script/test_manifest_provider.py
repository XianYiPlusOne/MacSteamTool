#!/usr/bin/env python3
"""Load installed macSteam in a disposable process; no live Steam config/saves are written."""
import http.server, pathlib, subprocess, tempfile, threading
ROOT = pathlib.Path(__file__).resolve().parents[1]
class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        mode = self.path.split('/')[1]
        bodies = {'valid': b'18446744073709551615', 'json': b'{"manifest_request_code":18446744073709551615}', 'invalid': b'123 garbage', 'overflow': b'18446744073709551616', 'large': b'1' * 5000}
        self.send_response(503 if mode == 'failure' else 302 if mode == 'redirect' else 200)
        if mode == 'redirect': self.send_header('Location', '/valid/1')
        self.end_headers()
        try: self.wfile.write(bodies.get(mode, b''))
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Server)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='fluent-provider-', dir=ROOT/'work') as tmp:
        path = pathlib.Path(tmp); (path/'.fluent-fixture').touch(); (path/'CloudRedirect').mkdir()
        run = subprocess.run([str(ROOT/'work/cloud-build/FluentProviderProbe'), str(pathlib.Path.home()/'Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib'), '/Applications/Steam.app/Contents/MacOS/macsteam.dylib', tmp, f'http://127.0.0.1:{server.server_port}'], capture_output=True, text=True, timeout=35)
        for line in (run.stdout + run.stderr).splitlines():
            if line.startswith(('PASS:', 'FAIL:')): print(line)
        if run.returncode: print('Probe exit:', run.returncode)
        raise SystemExit(run.returncode)
finally: server.shutdown()
