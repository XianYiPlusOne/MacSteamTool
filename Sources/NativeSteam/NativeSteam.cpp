// Independently adapted for macOS from SAM.API's documented interface layout.
// SAM.API copyright (c) 2024 Rick; zlib notice: Licenses/SAM-API.txt.
// This is a separate macOS implementation, not an original SAM release.
#include "NativeSteam.h"
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <string>
#include <chrono>
#include <thread>

struct CallbackMessage { int user, id; void *data; int size; };
struct FSContext {
    void *library = nullptr, *client = nullptr, *stats = nullptr, *utils = nullptr;
    int pipe = 0, user = 0, shift = 0;
    uint32_t app = 0;
    uint64_t steamID = 0;
    bool ready = false;
    bool (*getCallback)(int, CallbackMessage *, uint64_t *) = nullptr;
    void (*freeCallback)(int) = nullptr;
    std::string error;
};
template<typename Fn> static Fn method(void *object, int index) {
    return reinterpret_cast<Fn>((*reinterpret_cast<void ***>(object))[index]);
}
static bool waitCallback(FSContext *c, int id, uint64_t expectedUser = 0) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline) {
        CallbackMessage message{}; uint64_t call = 0;
        while (c->getCallback(c->pipe, &message, &call)) {
            bool matching = false; int32_t result = 0;
            if (message.user == c->user && message.id == id && message.data && message.size >= (id == 1101 ? 20 : 12)) {
                uint64_t game = 0;
                std::memcpy(&game, message.data, 8);
                std::memcpy(&result, static_cast<char *>(message.data) + 8, 4);
                matching = game == c->app;
                if (id == 1101) {
                    // Steam callback ABI is packed to four bytes on macOS.
                    uint64_t owner = 0; std::memcpy(&owner, static_cast<char *>(message.data) + 12, 8);
                    matching = matching && owner == expectedUser;
                }
            }
            c->freeCallback(c->pipe);
            if (matching) {
                if (result == 1) return true;
                c->error = "Steam callback EResult=" + std::to_string(result); return false;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    c->error = "Steam callback timed out; server acknowledgement was not received"; return false;
}
static bool statsInterface(FSContext *c) {
    if (c->stats) return true;
    auto get = method<void *(*)(void *, int, int, const char *)>(c->client, 13);
    c->stats = get(c->client, c->user, c->pipe, "STEAMUSERSTATS_INTERFACE_VERSION013");
    if (!c->stats) { c->shift = 1; c->stats = get(c->client, c->user, c->pipe, "STEAMUSERSTATS_INTERFACE_VERSION012"); }
    if (!c->stats) { c->error = "Steam user stats interface is unavailable"; return false; }
    return true;
}
static bool requestStats(FSContext *c, uint64_t owner) {
    if (!statsInterface(c)) return false;
    auto call = method<uint64_t (*)(void *, uint64_t)>(c->stats, 15 + c->shift)(c->stats, owner);
    if (!call) { c->error = "Steam refused RequestUserStats"; return false; }
    return waitCallback(c, 1101, owner);
}
FSContext *fs_create(const char *path, uint32_t app) { return fs_create_session(path, app, 1); }
FSContext *fs_create_session(const char *path, uint32_t app, int load_stats) {
    auto c = new FSContext(); c->app = app;
    if (!app || !path || path[0] != '/') { c->error = "Invalid Steam context"; return c; }
    auto id = std::to_string(app); setenv("SteamAppId", id.c_str(), 1); setenv("SteamGameId", id.c_str(), 1);
    c->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!c->library) { const char *e = dlerror(); c->error = e ? e : "Cannot load Steam client"; return c; }
    auto factory = reinterpret_cast<void *(*)(const char *, int *)>(dlsym(c->library, "CreateInterface"));
    c->getCallback = reinterpret_cast<bool (*)(int, CallbackMessage *, uint64_t *)>(dlsym(c->library, "Steam_BGetCallback"));
    c->freeCallback = reinterpret_cast<void (*)(int)>(dlsym(c->library, "Steam_FreeLastCallback"));
    if (!factory || !c->getCallback || !c->freeCallback) { c->error = "Steam client callback exports are unavailable"; return c; }
    c->client = factory("SteamClient018", nullptr);
    if (!c->client) { c->error = "SteamClient018 is unavailable"; return c; }
    c->pipe = method<int (*)(void *)>(c->client, 0)(c->client);
    if (!c->pipe) { c->error = "Steam is not running or its IPC pipe is unavailable"; return c; }
    c->user = method<int (*)(void *, int)>(c->client, 2)(c->client, c->pipe);
    if (!c->user) { c->error = "Sign into the native Steam client first"; return c; }
    void *utils = method<void *(*)(void *, int, const char *)>(c->client, 9)(c->client, c->pipe, "SteamUtils010");
    if (!utils || method<uint32_t (*)(void *)>(utils, 9)(utils) != app) { c->error = "Steam AppID context mismatch; refusing to edit achievements"; return c; }
    c->utils = utils;
    void *user = method<void *(*)(void *, int, int, const char *)>(c->client, 5)(c->client, c->user, c->pipe, "SteamUser023");
    if (!user || !(c->steamID = method<uint64_t (*)(void *)>(user, 2)(user))) { c->error = "Steam user interface is unavailable"; return c; }
    if (!load_stats) { c->ready = true; return c; }
    c->ready = requestStats(c, c->steamID); return c;
}
int fs_schema(FSContext *c, uint64_t publicUser) {
    if (!c || !c->ready || c->stats || !publicUser) return 0;
    // This session can only fetch definitions. It must never be used to read or
    // edit the current user's state after a successful foreign-user callback.
    c->ready = false;
    return requestStats(c, publicUser);
}
const char *fs_error(FSContext *c) { return c ? c->error.c_str() : "No Steam context"; }
int fs_ready(FSContext *c) { return c && c->ready; }
uint32_t fs_account(FSContext *c) { return c ? static_cast<uint32_t>(c->steamID) : 0; }
int fs_refresh(FSContext *c) { if (!c || !c->stats) return 0; c->ready = requestStats(c, c->steamID); return c->ready; }
uint32_t fs_count(FSContext *c) { return fs_ready(c) ? method<uint32_t (*)(void *)>(c->stats, 13 + c->shift)(c->stats) : 0; }
const char *fs_name(FSContext *c, uint32_t index) { return fs_ready(c) ? method<const char *(*)(void *, uint32_t)>(c->stats, 14 + c->shift)(c->stats, index) : nullptr; }
const char *fs_attribute(FSContext *c, const char *name, const char *attribute) { return fs_ready(c) ? method<const char *(*)(void *, const char *, const char *)>(c->stats, 11 + c->shift)(c->stats, name, attribute) : nullptr; }
int fs_get(FSContext *c, const char *name, uint32_t *timestamp) {
    if (!fs_ready(c)) return -1;
    bool achieved = false;
    if (!method<bool (*)(void *, const char *, bool *, uint32_t *)>(c->stats, 8 + c->shift)(c->stats, name, &achieved, timestamp)) return -1;
    return achieved ? 1 : 0;
}
int fs_set(FSContext *c, const char *name, int achieved) {
    return fs_ready(c) && method<bool (*)(void *, const char *)>(c->stats, (achieved ? 6 : 7) + c->shift)(c->stats, name);
}
int fs_store(FSContext *c) {
    if (!fs_ready(c) || !method<bool (*)(void *)>(c->stats, 9 + c->shift)(c->stats)) { if (c) c->error = "Steam refused StoreStats"; return 0; }
    return waitCallback(c, 1102);
}
void fs_destroy(FSContext *c) {
    if (!c) return;
    if (c->client && c->pipe) {
        if (c->user) method<void (*)(void *, int, int)>(c->client, 4)(c->client, c->pipe, c->user);
        method<bool (*)(void *, int)>(c->client, 1)(c->client, c->pipe);
    }
    // Steam owns background threads. The isolated worker exits immediately after cleanup;
    // unloading its dylib while those threads retire is unsafe.
    delete c;
}
