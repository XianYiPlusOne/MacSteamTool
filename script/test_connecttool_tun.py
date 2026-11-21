#!/usr/bin/env python3
"""Unprivileged tests of the real TUN probe's local socket/descriptor handling."""
import array
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

helper = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'work/connecttool-native-build/connecttool-tun-daemon').resolve())
with tempfile.TemporaryDirectory(prefix='fluent-tun-') as temp:
    path = str(Path(temp) / 'helper.sock')
    env = dict(os.environ, CONNECTTOOL_TUN_HELPER_SOCKET=path)
    def run():
        return subprocess.run([helper, '--probe'], env=env, capture_output=True, text=True, timeout=8)
    result = run()
    assert result.returncode != 0 and 'connect helper' in result.stderr, result

    def scenario(response):
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(path); server.listen(1)
            errors = []
            def serve():
                try:
                    connection, _ = server.accept()
                    with connection:
                        assert connection.recv(1024).startswith(b'OPEN ')
                        response(connection)
                except Exception as e: errors.append(e)
            thread = threading.Thread(target=serve, daemon=True); thread.start()
            result = run(); thread.join(timeout=5)
            assert not errors, errors
        Path(path).unlink()
        return result

    result = scenario(lambda c: c.sendall(b'OK if=utun999\n'))
    assert result.returncode != 0 and 'did not provide a TUN fd' in result.stderr, result
    def fragmented(c):
        with open('/dev/null', 'rb') as stream:
            c.sendmsg([b'OK i'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [stream.fileno()]))])
            time.sleep(.03)
            c.sendall(b'f=utun999\n')
    result = scenario(fragmented)
    assert result.returncode != 0 and 'invalid virtual interface' in result.stderr, result
    started = time.monotonic()
    result = scenario(lambda c: time.sleep(3))
    assert result.returncode != 0 and time.monotonic() - started < 5, result
    print('Passed: absent helper, missing descriptor, fragmented response, invalid descriptor, timeout')
