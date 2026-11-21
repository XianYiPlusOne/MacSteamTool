#!/usr/bin/env python3
"""Regression for distinct AppID/depot IDs after Steam uninstall/re-import."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source_root = root / 'Native/MacSteam/src'
with tempfile.TemporaryDirectory(prefix='fluent-depot-selection-') as tmp:
    tmp = Path(tmp)
    source = tmp / 'probe.c'
    source.write_text(r'''
#include "config/config.h"
#include "feats/apps.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
int sx_log_level = -1;
FILE *sx_log_file;
int sx_log_once_seen(const void *site, unsigned long key) { return 0; }
int main(int argc, char **argv) {
    sx_config_t *cfg = calloc(1, sizeof(*cfg));
    assert(sx_config_load(argv[1], cfg) == 0);
    sx_config_current = cfg;
    assert(!sx_apps_is_owned_for_depot(1601582, 1601580, 0));
    sx_apps_force_ready();
    // All three callbacks must survive a cold native ownership cache.
    assert(sx_apps_is_owned_for_depot(1601582, 1601580, 0));
    assert(sx_apps_is_owned_for_depot(1601583, 1601580, 0));
    assert(sx_apps_is_owned_for_depot(2791490, 1601580, 0));
    assert(!sx_apps_is_owned_for_depot(9999999, 1601580, 0));
    assert(!sx_apps_is_owned_for_depot(1601582, 9999999, 0));
    assert(!sx_apps_is_owned_for_depot(9999998, 1601580, 0)); // disabled key owner
    assert(sx_apps_is_owned_for_depot(9999999, 9999999, 1)); // native success
    // Same config snapshot can be replaced repeatedly; never cache a positive.
    for (int i = 0; i < 3; ++i) {
        sx_config_current = NULL;
        assert(!sx_apps_is_owned_for_depot(1601582, 1601580, 0));
        sx_config_current = cfg;
        assert(sx_apps_is_owned_for_depot(1601582, 1601580, 0));
    }
    int count = cfg->app_count;
    cfg->app_count = 0;
    assert(!sx_apps_is_owned_for_depot(1601582, 1601580, 0));
    cfg->app_count = count;
    cfg->dk_count = 0;
    assert(!sx_apps_is_owned_for_depot(1601582, 1601580, 0));
    sx_config_current = NULL;
    sx_config_free(cfg); free(cfg);
    puts("PASS: base/DLC depot selection, cold cache, repeated import, removal, native passthrough");
}
''')
    config = tmp / 'config.yaml'
    config.write_text('Apps:\n  - 1601580\n  - 2791490\n  - 2791500\nDepotKeys:\n' +
        ''.join(f'  {app}:\n    {depot}: {"ab" * 32}\n' for app, depot in
                [(1601580, 1601582), (2791500, 1601583), (9999997, 9999998)]))
    exe = tmp / 'probe'
    subprocess.run(['clang', '-std=c11', '-I', str(source_root), str(source),
                    str(source_root / 'config/config.c'), str(source_root / 'feats/apps.c'),
                    '-o', str(exe)], check=True)
    subprocess.run([str(exe), str(config)], check=True)
