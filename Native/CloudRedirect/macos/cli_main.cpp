// Linux CLI wrapper: dlopens cloud_redirect.dylib and calls CloudRedirect_CliMain.
// Mirrors src/platform/win/cli_main.cpp. Must be 32-bit to load the 32-bit .so.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

typedef int (*CliMainFn)(int argc, char** argv);

// Resolve cloud_redirect.dylib next to this executable, else the loader search path.
static void resolveSoPath(char* out, size_t outSize) {
    char exePath[PATH_MAX];
    uint32_t size = sizeof(exePath);
    ssize_t len = _NSGetExecutablePath(exePath, &size) == 0 ? strlen(exePath) : -1;
    if (len <= 0) {
        snprintf(out, outSize, "cloud_redirect.dylib");
        return;
    }
    exePath[len] = '\0';

    char* lastSlash = strrchr(exePath, '/');
    if (lastSlash) {
        *(lastSlash + 1) = '\0';
        snprintf(out, outSize, "%scloud_redirect.dylib", exePath);
    } else {
        snprintf(out, outSize, "cloud_redirect.dylib");
    }
}

int main(int argc, char** argv) {
    char soPath[PATH_MAX];
    resolveSoPath(soPath, sizeof(soPath));

    void* handle = dlopen(soPath, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        // Fall back to loader search path (LD_LIBRARY_PATH / rpath).
        handle = dlopen("cloud_redirect.dylib", RTLD_NOW | RTLD_LOCAL);
    }
    if (!handle) {
        fprintf(stderr, "Error: Cannot load %s (%s)\n", soPath, dlerror());
        return 1;
    }

    dlerror();
    CliMainFn cliMain = (CliMainFn)dlsym(handle, "CloudRedirect_CliMain");
    const char* symErr = dlerror();
    if (!cliMain || symErr) {
        fprintf(stderr, "Error: Cannot find CloudRedirect_CliMain in %s (%s)\n",
                soPath, symErr ? symErr : "null symbol");
        dlclose(handle);
        return 1;
    }

    // Prepend "--cli" if the caller didn't.
    int exitCode;
    if (argc >= 2 && strcmp(argv[1], "--cli") == 0) {
        exitCode = cliMain(argc, argv);
    } else {
        char** newArgv = (char**)malloc((argc + 2) * sizeof(char*));
        newArgv[0] = argv[0];
        newArgv[1] = (char*)"--cli";
        for (int i = 1; i < argc; i++) {
            newArgv[i + 1] = argv[i];
        }
        newArgv[argc + 1] = nullptr;
        exitCode = cliMain(argc + 1, newArgv);
        free(newArgv);
    }

    dlclose(handle);
    return exitCode;
}
