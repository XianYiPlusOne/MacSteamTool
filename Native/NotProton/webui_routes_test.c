// Real upstream registration/factory functions; no Steam process or IPC.
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "feats/webui.c"
int np_log_level = 0;
FILE *np_log_file = NULL;
int np_get_section_containing(const struct mach_header_64 *m, intptr_t s, uintptr_t a, uintptr_t *b, size_t *z) { return -1; }
int np_find_segment(const struct mach_header_64 *m, intptr_t s, const char *n, uintptr_t *b, size_t *z) { return -1; }
static uintptr_t fake_new(void) { return 0; }
static int registration_result = 1;
static int fake_register(uintptr_t r, void *v) { return registration_result; }
static int fake_handler(uintptr_t a, uintptr_t b) { return 1; }
static uintptr_t fake_job(uintptr_t a, uintptr_t b) { return (uintptr_t)calloc(1, 64); }
int main(void) {
    _Alignas(8) uintptr_t types[8] = {0};
    types[3] = (uintptr_t)fake_new;
    g_registry = (uintptr_t)types;
    g_register_fn = (uintptr_t)fake_register;
    g_text_base = ((uintptr_t)fake_new) & ~(uintptr_t)3;
    g_text_end = g_text_base + 64;
    g_clone_words = 4;
    g_stock_factory = (uintptr_t)fake_job;
    const char *routes[] = {"GetCompatTools", "SpecifyCompatTool", "SetDefaults", "SetToolDefaults", "ApplyToolDefaults", "PrefixState", "RebuildPrefix", "BackupAndRebuildPrefix", "OpenPrefixLog"};
    for (int i = 0; i < 9; ++i) {
        if (!np_webui_register_route(routes[i], (uintptr_t)types, (uintptr_t)types, fake_handler)) {
            fprintf(stderr, "FAIL: required route %d %s rejected\n", i + 1, routes[i]); return 1;
        }
    }
    registration_result = 0;
    assert(!np_webui_register_route("RejectedBySteam", (uintptr_t)types, (uintptr_t)types, fake_handler));
    assert(g_route_count == 9); // A failed registration cannot consume a slot.
    registration_result = 1;
    for (int i = 9; i < MAX_ROUTES; ++i)
        assert(np_webui_register_route("FutureRoute", (uintptr_t)types, (uintptr_t)types, fake_handler));
    assert(!np_webui_register_route("Overflow", (uintptr_t)types, (uintptr_t)types, fake_handler));
    assert(g_route_count == MAX_ROUTES);
    for (int i = 0; i < MAX_ROUTES; ++i) {
        assert(g_job_factories[i]);
        uintptr_t job = g_job_factories[i](0, 0);
        assert(job && *(uintptr_t*)job == (uintptr_t)&g_routes[i].vtable[2]);
        assert(g_routes[i].handler == fake_handler);
        free((void*)job);
    }
    puts("PASS: all nine required routes, every factory identity, rejected-registration reuse, bounded capacity overflow");
}
