#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
namespace FluentPins {
struct Pin { uint64_t gid; uint64_t size; bool operator==(const Pin&) const = default; };
using Pins = std::unordered_map<uint32_t, Pin>;
Pins Read(const std::string& config, const std::string& depotCache);
uintptr_t FindClient();
}
extern "C" int FluentPinsInstall();
extern "C" void FluentPinsReload();
extern "C" void FluentPinsRemove();
extern "C" unsigned FluentPinsCount();
