// Explicit, correlated reload requests, consumed on the Steam engine IPC thread.
#include "hot_refresh.h"
#include "reconcile.h"
#include "../config/config.h"
#include "../util/file.h"
#include "../util/log.h"
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static char config_path[1024], last_request[65];
static _Atomic int ready;
static _Atomic int logged_on;
void sx_hot_refresh_login(int logged) { atomic_store(&logged_on, logged); }
static int busy, snapshots;
// Readers in existing hooks can retain a config pointer across a Steam call.
// Keep published immutable snapshots alive; bound memory and fall back at the cap.
static sx_config_t *retained[32];
static void reply(const char *token, const char *hash, const char *status) {
    char path[1200], tmp[1240];
    snprintf(path, sizeof(path), "%s.refresh-result", config_path);
    snprintf(tmp, sizeof(tmp), "%s.%d.tmp", path, getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%s %d %s %s\n", token, getpid(), hash, status);
    if (fclose(f) == 0) rename(tmp, path); else unlink(tmp);
}
void sx_hot_refresh_start(void) {
    sx_file_config_path(config_path, sizeof(config_path));
    ready = 1;
}
void sx_hot_refresh_poll(void *app_manager) {
    if (!ready || !app_manager || !atomic_load(&logged_on) || !sx_reconcile_login_observed()) return;
#ifndef SX_REFRESH_TEST
    // The engine IPC thread owns its pipes; the macOS UI thread does not.
    char thread_name[64] = {0};
    pthread_getname_np(pthread_self(), thread_name, sizeof(thread_name));
    if (strcmp(thread_name, "IPC:CSteamEngine")) return;
#endif
    if (busy) return;
    static time_t checked;
    time_t now = time(NULL);
    if (now == checked) return;
    checked = now;
    char path[1200], token[65], hash[65], extra;
    int pid = 0;
    snprintf(path, sizeof(path), "%s.refresh-request", config_path);
    FILE *f = fopen(path, "r");
    if (!f) return;
    int fields = fscanf(f, "%64s %d %64s %c", token, &pid, hash, &extra);
    fclose(f);
    if (fields != 3 || pid != getpid() || strlen(token) != 36 || strlen(hash) != 64 || !strcmp(token, last_request)) return;
    strcpy(last_request, token);
    busy = 1;
    const char *status = "restart-required";
    sx_config_t *next = NULL;
    if (!sx_reconcile_can_refresh() || snapshots == 32) goto done;
    size_t size = 0;
    unsigned char *data = sx_slurp_file(config_path, &size), digest[CC_SHA256_DIGEST_LENGTH];
    if (!data) goto done;
    CC_SHA256(data, (CC_LONG)size, digest); free(data);
    char actual[65];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(actual + 2*i, 3, "%02x", digest[i]);
    if (strcmp(actual, hash)) { status = "config-changed"; goto done; }
    next = calloc(1, sizeof(*next));
    if (!next || sx_config_load(config_path, next)) goto done;
    // Only additions/key updates are safe without replacing the login license list.
    sx_config_t *old = sx_config_current;
    if (!old || next->pkg_count != old->pkg_count) goto done;
    for (int i = 0; i < old->pkg_count; ++i) if (!sx_config_has_package(next, old->package_ids[i])) goto done;
    for (int i = 0; i < old->app_count; ++i) if (!sx_config_has_app(next, old->app_ids[i])) goto done;
    // Reject concurrent writes during parsing too.
    data = sx_slurp_file(config_path, &size);
    if (!data) goto done;
    CC_SHA256(data, (CC_LONG)size, digest); free(data);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(actual + 2*i, 3, "%02x", digest[i]);
    if (strcmp(actual, hash)) { status = "config-changed"; goto done; }
    retained[snapshots++] = next;
    sx_config_current = next;
    sx_reconcile_set_library_refresh_apps(next->app_ids, next->app_count);
    next = NULL;
    sx_reconcile_arm_after_inject();
    sx_reconcile_arm_library_refresh();
    if (sx_reconcile_fire_library_refresh(app_manager)) status = "emitted";
done:
    if (next) { sx_config_free(next); free(next); }
    reply(token, hash, status);
    SX_LOG("hot refresh %s: %s", token, status);
    busy = 0;
}
