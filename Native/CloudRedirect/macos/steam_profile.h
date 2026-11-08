#pragma once
#include "steam_kv_injector.h"
#include <cstddef>
namespace SteamProfile {
bool ResolveKv(uintptr_t base,size_t size,SteamKvInjector::ResolvedKvAddrs& out);
}
