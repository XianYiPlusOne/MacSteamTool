#pragma once
#include <string>
#include <unistd.h>

// Match AppPaths when a component is started without an explicit data directory.
inline std::string MacSteamToolDataDirectory(const std::string& home) {
    const auto support = home + "/Library/Application Support/";
    const auto current = support + "MacSteamTool";
    const auto legacy = support + "FluentSteamMac";
    return access(current.c_str(), F_OK) != 0 && access(legacy.c_str(), F_OK) == 0 ? legacy : current;
}
