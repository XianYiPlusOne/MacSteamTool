#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ZIP="$ROOT_DIR/work/windows-runtime/python-3.12.10-embed-amd64.zip"
mkdir -p "$ROOT_DIR/work/windows-runtime" "$ROOT_DIR/work/windows-test-runtime"
if [[ ! -f "$RUNTIME_ZIP" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' -o "$RUNTIME_ZIP"
fi
python3 - "$RUNTIME_ZIP" "$ROOT_DIR/work/windows-test-runtime" <<'PY'
from pathlib import Path
import sys,hashlib,zipfile
source,dest=map(Path,sys.argv[1:])
assert hashlib.sha256(source.read_bytes()).hexdigest()=='4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3','Python archive checksum mismatch'
with zipfile.ZipFile(source) as z:
    assert all('/' not in name and '\\' not in name and name not in ('.','..') for name in z.namelist())
    z.extractall(dest)
PY
