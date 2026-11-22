#pragma once
#include "../../AppSupportDirectory.h"
#include <cstdlib>
#include <string>
#include <pwd.h>
#include <unistd.h>


inline bool InFlatpak() {
    static const bool cached = (access("/.flatpak-info", F_OK) == 0);
    return cached;
}

inline std::string XdgHome() {
    const char* home = getenv("HOME");
    if (home && home[0]) return home;
    struct passwd* pw = getpwuid(getuid());
    if (pw && pw->pw_dir) return pw->pw_dir;
    return "/tmp";
}

inline std::string XdgConfigHome() {
    const char* root = getenv("FLUENT_CLOUD_ROOT");
    if(root && root[0]=='/') return root;
    return MacSteamToolDataDirectory(XdgHome());
}
inline std::string XdgDataHome() { return XdgConfigHome(); }
