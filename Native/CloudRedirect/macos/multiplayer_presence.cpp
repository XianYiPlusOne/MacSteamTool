#include "multiplayer_presence.h"
#include <algorithm>
#include <libproc.h>
#include <string_view>
#include <unordered_set>

namespace MultiplayerPresence {
static bool isMultiplayerApp(uint64_t pid) {
    if (!pid || pid > INT32_MAX) return false;
    char path[PROC_PIDPATHINFO_MAXSIZE]{};
    return proc_pidpath(static_cast<int>(pid), path, sizeof(path)) > 0 &&
        std::string_view(path).ends_with(".app/Contents/MacOS/MacSteamTool");
}

static bool appProcessesOnly(const std::vector<PB::Field>& game) {
    bool found = false;
    for (const auto& field : game) {
        uint64_t pid;
        if (field.fieldNum == 9) {
            if (field.wireType != PB::Varint) return false;
            pid = field.varintVal;
        } else if (field.fieldNum == 32) {
            if (field.wireType != PB::LengthDelimited) return false;
            auto process = PB::Parse(field.data, field.dataLen);
            auto* child = PB::FindField(process, 1);
            if (!child || child->wireType != PB::Varint || !child->varintVal) return false;
            pid = child->varintVal;
        } else {
            continue;
        }
        if (!pid) continue;
        if (!isMultiplayerApp(pid)) return false;
        found = true;
    }
    return found;
}

bool PreferGames(std::vector<PB::Field>& fields) {
    auto isGameEntry = [](const PB::Field& field) {
        return field.fieldNum == 1 && field.wireType == PB::LengthDelimited;
    };
    if (std::count_if(fields.begin(), fields.end(), isGameEntry) < 2) return false;
    bool hasGame = false;
    std::unordered_set<const uint8_t*> helpers;
    for (const auto& entry : fields) {
        if (!isGameEntry(entry)) continue;
        const auto game = PB::Parse(entry.data, entry.dataLen);
        const auto* id = PB::FindField(game, 2);
        if (!id || id->wireType != PB::Fixed64 || !id->varintVal) continue;
        if (id->varintVal == 480 && appProcessesOnly(game))
            helpers.insert(entry.data);
        else
            hasGame = true;
    }
    if (!hasGame || helpers.empty()) return false;
    std::erase_if(fields, [&](const PB::Field& field) { return helpers.contains(field.data); });
    return true;
}
}
