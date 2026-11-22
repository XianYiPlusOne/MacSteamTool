#pragma once

#include <cstdint>
#include <cstddef>
#include <string>

namespace CloudHooks
{
    // Called after hooks are installed to store the original function pointers
    void SetOriginal(void* origSlot5);

    // Resolve protobuf helper functions from the loaded steamclient.so.
    // Must be called after steamclient is loaded. Returns true on success.
    bool ResolveProtobufHelpers(void* steamclientBase, size_t steamclientSize);

    // Install the GamesPlayed observer (playtime tracking) using the resolved
    // protobuf serializer. Call after ResolveProtobufHelpers succeeds.
    void InstallGamesPlayedObserver(uintptr_t steamclientBase, size_t steamclientSize);

    // Signal hooks to stop and wait for in-flight calls to drain.
    void InitializeStorage();
    void ObserveAccount(uint64_t steamID);
    void BeginShutdown();
    void ShutdownStorage();
    std::string StatusJSONFields();
}
