// Relaunch persistence
#include "hooks.h"
#include "../util/log.h"

#include <spawn.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>

extern int DobbyHook(void *address, void *replace_call, void **origin_call);
extern void *DobbySymbolResolver(const char *image_name, const char *symbol_name);

typedef int (*fn_execv)(const char *path, char *const argv[]);
typedef int (*fn_execve)(const char *path, char *const argv[], char *const envp[]);
typedef int (*fn_posix_spawn)(pid_t *pid, const char *path,
                              const posix_spawn_file_actions_t *fa,
                              const posix_spawnattr_t *attr,
                              char *const argv[], char *const envp[]);

static fn_execv        orig_execv        = NULL;
static fn_execve       orig_execve       = NULL;
static fn_posix_spawn  orig_posix_spawn  = NULL;

// MacSteamTool deploys into the native Steam bundle and manages its LSEnvironment.
// Native Steam relaunches must stay native; no companion launcher is required.
static int target_keeps_insert(const char *path) {
    if (!path)
        return 1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, "steam_osx") == 0;
}

static char **strip_dyld_insert(char *const envp[]) {
    if (!envp) return NULL;

    int count = 0;
    for (int i = 0; envp[i]; i++)
        count++;

    char **clean = malloc(sizeof(char *) * (count + 1));
    if (!clean) return NULL;

    int j = 0;
    for (int i = 0; envp[i]; i++) {
        if (strncmp(envp[i], "DYLD_INSERT_LIBRARIES=", 22) != 0)
            clean[j++] = envp[i];
    }
    clean[j] = NULL;
    return clean;
}

static void trace_exec(const char *api, const char *path, char *const argv[], char *const envp[]) {
    SX_LOG("[relaunch] %s path='%s'", api, path ? path : "(null)");
    (void)argv; // Game launch arguments may contain private session data.
    int has_insert = 0, has_bundle = 0;
    if (envp) {
        for (int i = 0; envp[i]; i++) {
            if (strncmp(envp[i], "DYLD_INSERT_LIBRARIES=", 22) == 0) {
                has_insert = 1;
                SX_LOG("[relaunch]   env DYLD_INSERT_LIBRARIES present: %s", envp[i] + 22);
            }
            if (strncmp(envp[i], "STEAM_APP_BUNDLE_PATH=", 22) == 0)
                has_bundle = 1;
        }
    } else {
        SX_LOG("[relaunch]   envp=NULL (inherits current environ)");
    }
    SX_LOG("[relaunch]   -> DYLD_INSERT in envp: %s, STEAM_APP_BUNDLE_PATH: %s%s",
           has_insert ? "YES" : "NO",
           has_bundle ? "YES" : "NO",
           envp ? "" : " (envp NULL, cannot tell from here)");
}

static int hook_execv(const char *path, char *const argv[]) {
    trace_exec("execv", path, argv, NULL);
    return orig_execv(path, argv);
}

static int hook_execve(const char *path, char *const argv[], char *const envp[]) {
    trace_exec("execve", path, argv, envp);
    char **clean_env = target_keeps_insert(path) ? NULL : strip_dyld_insert(envp);
    int rc = orig_execve(path, argv,
                         clean_env ? (char *const *)clean_env : envp);
    free(clean_env);
    return rc;
}

static int hook_posix_spawn(pid_t *pid, const char *path,
                            const posix_spawn_file_actions_t *fa,
                            const posix_spawnattr_t *attr,
                            char *const argv[], char *const envp[]) {
    trace_exec("posix_spawn", path, argv, envp);
    char **clean_env = target_keeps_insert(path) ? NULL : strip_dyld_insert(envp);
    int rc = orig_posix_spawn(pid, path, fa, attr, argv,
                              clean_env ? (char *const *)clean_env : envp);
    free(clean_env);
    return rc;
}

static void hook_one(const char *sym, void *repl, void **orig) {
    void *addr = DobbySymbolResolver("libsystem_kernel.dylib", sym);
    if (!addr)
        addr = DobbySymbolResolver(NULL, sym);
    if (!addr) {
        SX_WARN("[relaunch] could not resolve %s", sym);
        return;
    }
    int rc = DobbyHook(addr, repl, orig);
    if (rc == 0)
        SX_LOG("[relaunch] hooked %s @ %p", sym, addr);
    else
        SX_WARN("[relaunch] DobbyHook(%s) failed rc=%d", sym, rc);
}

void sx_hooks_relaunch_install(void) {
    hook_one("execv",       (void *)hook_execv,       (void **)&orig_execv);
    hook_one("execve",      (void *)hook_execve,      (void **)&orig_execve);
    hook_one("posix_spawn", (void *)hook_posix_spawn, (void **)&orig_posix_spawn);
}
