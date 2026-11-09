#pragma once
#include <cstdint>
#include <cstddef>
namespace OnlineFix {
bool Install(uintptr_t base, size_t size);
void Remove();
bool Installed();
uint32_t ActiveApp();
bool HasOption(const char* command);
bool RewriteLaunch(uint64_t& gameID, const char* command, bool managed);
void RestoreOverlay(uint64_t gameID, uint64_t& overlay);
uint32_t RestoreAppID(uint32_t native);
void ObserveRunning(bool aliasPresent);
}
