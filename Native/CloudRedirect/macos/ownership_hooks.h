#pragma once
#include <cstddef>
#include <cstdint>

// Library ownership presentation for explicitly configured macSteam games.
// Wraps macSteam's helper; never installs a second detour on Steam's entry.
namespace OwnershipHooks {
bool Install(uintptr_t steamBase, size_t steamSize);
void Remove();
bool Installed();
unsigned Repaired();
unsigned MissingOwner();
}
