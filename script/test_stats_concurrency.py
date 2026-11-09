#!/usr/bin/env python3
"""Local filesystem CAS and transport-independent Drive snapshot concurrency."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='stats-concurrency-', dir=root / 'work') as folder:
    subprocess.run([str(root / 'work/cloud-build/FluentStatsConcurrencyProbe'), str(Path(folder) / 'provider')], check=True, timeout=45)
