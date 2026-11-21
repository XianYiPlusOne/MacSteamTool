#!/usr/bin/env python3
"""Exercise the vendored upstream config parser, offline, with dummy keys."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="fluent-san14-probe-") as folder:
    folder = Path(folder)
    source = folder / "probe.c"
    source.write_text(r'''#include "config.h"
#include <stdio.h>
#include <stdlib.h>
int sx_log_level = -1;
FILE *sx_log_file = NULL;
int main(int argc, char **argv) {
    sx_config_t *cfg = calloc(1, sizeof(*cfg));
    if (!cfg || sx_config_load(argv[1], cfg) != 0) return 2;
    int depots[64]; char key[65];
    int n = sx_config_app_depots(cfg, 872410, depots, 64);
    int found = sx_config_get_depot_key_any(cfg, 872415, key, sizeof(key)) == 0;
    int expected = atoi(argv[2]);
    printf("upstream parser: depots=%d, 872415=%s\n", n, found ? "present" : "missing");
    int ok = found == expected && n == 4 + expected;
    sx_config_free(cfg); free(cfg);
    return ok ? 0 : 1;
}
''')
    exe = folder / "probe"
    config = root / "Native/MacSteam/src/config"
    subprocess.run(["clang", "-std=c11", "-I", str(config), str(source), str(config / "config.c"), "-o", str(exe)], check=True)
    for complete in (False, True):
        yaml = "Apps:\n  - 872410\nDepotKeys:\n  872410:\n"
        for depot in range(872411, 872416 if complete else 872415):
            yaml += f"    {depot}: {'ab' * 32}\n"
        path = folder / "config.yaml"
        path.write_text(yaml)
        subprocess.run([str(exe), str(path), str(int(complete))], check=True)
print("PASS: vendored upstream parser preserves missing/present depot state; no Steam process or real credentials used")
