#!/usr/bin/env python3
"""Prove both DYLD startup slices load, without launching Steam or hooks."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
libraries = [(ROOT / "work/cloud-build/cloud_redirect.dylib", "CR_GetVersion"),
             (ROOT / "work/pins-build/fluent_manifest.dylib", "FluentPinsCount")]
with tempfile.TemporaryDirectory(prefix="FluentBootstrapProbe-") as temp:
    stage = Path(temp)
    source = stage / "probe.c"
    source.write_text('''#include <dlfcn.h>
#include <string.h>
int main(int argc, char **argv) {
    for (int i = 1; i + 1 < argc; i += 2) {
        void *lib = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        if (!lib || !dlsym(lib, argv[i+1])) return 1;
#if defined(__x86_64__)
        const char *(*marker)(void) = dlsym(lib, "FluentBootstrapOnly");
        if (!marker || strcmp(marker(), "x86_64-bootstrap-no-hooks")) return 2;
#endif
    }
    return 0;
}
''')
    for arch in ("x86_64", "arm64"):
        binary = stage / ("probe-" + arch)
        subprocess.run(["clang", "-arch", arch, "-mmacosx-version-min=15.0", str(source), "-o", str(binary)], check=True)
        env = {k: v for k, v in os.environ.items() if k in ("HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG")}
        env["DYLD_INSERT_LIBRARIES"] = ":".join(str(p) for p, _ in libraries)
        args = [str(binary)]
        for library, symbol in libraries:
            args += [str(library), "FluentBootstrapOnly" if arch == "x86_64" else symbol]
        subprocess.run(args, env=env, check=True, timeout=20)
        print("PASS:", arch, "startup loads both extensions;", "no-op bootstrap slices" if arch == "x86_64" else "real ARM64 exports retained")
