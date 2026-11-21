#include <assert.h>
#include "../MacSteam/src/hooks/hook_relaunch.c"

int sx_log_level = -1;
FILE *sx_log_file = NULL;
int DobbyHook(void *a, void *b, void **c) { return 0; }
void *DobbySymbolResolver(const char *a, const char *b) { return NULL; }
static char *const *expected_args;
static int capture(const char *path, char *const argv[]) {
    assert(argv == expected_args);
    assert(strcmp(path, "/bin/sh") == 0);
    return 17;
}
int main(void) {
    char *restart[] = {"sh", "-c", "open -n '/Applications/Steam.app'", NULL};
    expected_args = restart;
    orig_execv = capture;
    assert(hook_execv("/bin/sh", restart) == 17);
    assert(target_keeps_insert("/Applications/Steam.app/Contents/MacOS/steam_osx"));
    assert(!target_keeps_insert("/usr/bin/open"));
    char *env[] = {"DYLD_INSERT_LIBRARIES=fixture", "KEEP=1", NULL};
    char **clean = strip_dyld_insert(env);
    assert(clean && strcmp(clean[0], "KEEP=1") == 0 && clean[1] == NULL);
    free(clean);
    puts("PASS: Steam restarts retain native argv; no companion launcher is opened");
}
