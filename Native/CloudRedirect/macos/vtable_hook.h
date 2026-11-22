#pragma once

#include <cstdint>
#include <cstddef>

namespace VtableHook
{
    // Resolved vtable state
    struct VtableInfo
    {
        void** vtable;              // Pointer to the function pointer array (past offset-to-top + typeinfo)
        void*  origSlot5;           // BYieldingSendMessageAndGetReply
    };

    // Find steamclient.so in memory via /proc/self/maps.
    // Returns base address, sets size. Returns 0 on failure.
    uintptr_t FindSteamclient(size_t& outSize);

    // Locate CClientUnifiedServiceTransport vtable via RTTI scan.
    // steamBase/steamSize from FindSteamclient().
    // Returns pointer to function pointer array (slot 0), or nullptr.
    void** FindTransportVtable(uintptr_t steamBase, size_t steamSize);

    // Locate the primary vtable for a type by its Itanium-mangled RTTI name
    // (e.g. "22CMsgClientGetUserStatsE"). Returns slot-0 pointer or nullptr.
    void** FindVtableByRTTIName(const char* mangledName,
                                uintptr_t steamBase, size_t steamSize);

    // Find a global instance whose first word holds `vtablePtr` by scanning
    // writable ranges. Returns nullptr if none found.
    void* FindGlobalWithVtable(void* vtablePtr,
                               uintptr_t steamBase, size_t steamSize);

    // Save the statistics transport slot in `info`.
    bool InstallHooks(void** vtable, VtableInfo& info);

    // Restore original vtable slots.
    void RemoveHooks(const VtableInfo& info);
}
