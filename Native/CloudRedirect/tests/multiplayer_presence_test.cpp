#include "gamesplayed_hook.h"
#include "protobuf.h"
#include "runtime_settings.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

static PB::Writer game(uint64_t id, int pid = 0, int listedPID = 0) {
    PB::Writer entry;
    entry.WriteFixed64(2, id);
    if (pid) entry.WriteVarint(9, pid);
    if (listedPID) {
        PB::Writer process;
        process.WriteVarint(1, listedPID);
        entry.WriteSubmessage(32, process);
    }
    return entry;
}

static PB::Writer list(std::initializer_list<PB::Writer> games) {
    PB::Writer body;
    body.WriteVarint(2, 17);
    for (const auto& entry : games) body.WriteSubmessage(1, entry);
    return body;
}

int main() {
    // CMake places this executable at the bundled helper's relative path.
    const auto helper = game(480, getpid()), listedHelper = game(480, 0, getpid());
    const auto played = game(123), spacewar = game(480, getppid());
    const auto shortcut = game(0x8123456702000000ULL);
    char path[] = "/tmp/fluent-multiplayer-XXXXXX";
    if (!mkdtemp(path)) return 1;
    std::filesystem::path root(path);
    std::filesystem::create_directories(root / "CloudRedirect");
    setenv("FLUENT_CLOUD_ROOT", path, 1);
    setenv("FLUENT_CLOUD_STEAM", (root / "Steam").c_str(), 1);
    setenv("MACSTEAM_CONFIG", (root / "config.yaml").c_str(), 1);
    std::ofstream(root / "config.yaml") << "Apps:\n  - 123  # Fixture game\n";
    auto settings = root / "CloudRedirect/runtime.json";
    auto mode = [&](std::string name) {
        std::ofstream(settings) << R"({"presence":")" << name << R"(","presenceApps":{"123":"Fixture game"}})";
        std::filesystem::permissions(settings, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
        RuntimeSettings::Reload();
    };
    bool passed = true;
    auto check = [&](const char* scenario, const PB::Writer& input, const PB::Writer& expected) {
        for (unsigned type : {742u, 715u, 5410u}) {
            std::vector<uint8_t> output;
            bool changed = GamesPlayedHook::FilterPresence(type, input.Data(), output);
            if ((changed ? output : input.Data()) != expected.Data()) {
                std::cerr << "Failed: " << scenario << " (" << type << ")\n";
                passed = false;
            }
        }
    };
    mode("unchanged");
    check("helper only", list({helper}), list({helper}));
    check("game started first", list({played, helper}), list({played}));
    check("game started last", list({listedHelper, played}), list({played}));
    check("genuine Spacewar", list({spacewar, helper}), list({spacewar}));
    check("PID unavailable", list({played, game(480)}), list({played, game(480)}));
    auto shared = game(480, getpid(), getppid());
    check("game sharing the helper entry", list({played, shared}), list({played, shared}));
    check("other games retain order", list({spacewar, helper, shortcut}), list({spacewar, shortcut}));
    mode("automatic");
    auto titled = game(480);
    titled.WriteString(7, "Fixture game");
    check("game keeps its normal formatted title", list({played, helper}), list({titled}));
    check("actual Spacewar retains its identity", list({spacewar, played, helper}), list({spacewar, played}));
    mode("none");
    check("hidden game stays hidden", list({played, helper}), list({}));
    std::filesystem::remove_all(root);
    return passed ? 0 : 1;
}
