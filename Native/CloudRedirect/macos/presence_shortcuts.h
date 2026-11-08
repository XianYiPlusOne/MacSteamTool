#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace PresenceShortcuts {
// Only registered shortcut entries, never byte patterns inside string values.
std::vector<uint64_t> Parse(const std::vector<uint8_t>& bytes);
std::vector<uint64_t> Read(const std::string& steamRoot, uint32_t account);
}
