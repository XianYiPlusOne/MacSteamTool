// Isolated test library. No Steam process, account, network or disk state is accessed.
#include <cstdint>
#include <cstring>
#include <cstdlib>
struct Object { void **table; };
struct Callback { int user, id; void *data; int size; };
#pragma pack(push, 4)
struct Result { uint64_t game; int32_t result; uint64_t owner; };
#pragma pack(pop)
static void *clientTable[18]{}, *utilsTable[10]{}, *statsTable[17]{}, *userTable[3]{};
static Object client{clientTable}, utils{utilsTable}, stats{statsTable}, account{userTable};
static int pending = 0, decoy = 0;
static uint64_t requestedOwner = 0;
static uint64_t steamID(void*) { return 76561197960265729ULL; }
static void* getUser(void*, int, int, const char*) { return &account; }
static bool first = false, second = true;
static uint32_t app() { return std::strtoul(std::getenv("SteamAppId"), nullptr, 10); }
static int pipe(void *) { return 1; }
static bool release(void *, int) { return true; }
static int user(void *, int) { return 1; }
static void releaseUser(void *, int, int) {}
static void *getUtils(void *, int, const char *) { return &utils; }
static uint32_t getApp(void *) { return app() == 481 ? 480 : app(); }
static uint64_t request(void *, uint64_t owner) { if(app()==486)return 0; requestedOwner=owner;pending=1101;decoy=app()==487?3:0;return 42; }
static bool get(void *, const char *name, bool *value, uint32_t *time) {
    if (std::strcmp(name, "FIRST") == 0) *value = first;
    else if (std::strcmp(name, "SECOND") == 0) *value = second;
    else return false;
    *time = *value ? 100 : 0; return true;
}
static bool set(void *, const char *name) { if (std::strcmp(name, "FIRST") == 0) first = true; else second = true; return true; }
static bool clear(void *, const char *name) { if (std::strcmp(name, "FIRST") == 0) first = false; else second = false; return true; }
static bool store(void *) { pending = 1102; return true; }
static const char *attribute(void *, const char *name, const char *key) { return std::strcmp(key, "name") == 0 ? name : "Fixture achievement"; }
static uint32_t count(void *) { return app() == 484 ? 20000 : 2; }
static const char *name(void *, uint32_t index) { return index == 0 ? "FIRST" : "SECOND"; }
static void *getStats(void *, int, int, const char *version) {
 if(app()==485 && std::strstr(version,"013"))return nullptr;
 int shift=app()==485?1:0;
 statsTable[6+shift]=(void*)set; statsTable[7+shift]=(void*)clear; statsTable[8+shift]=(void*)get;
 statsTable[9+shift]=(void*)store;statsTable[11+shift]=(void*)attribute;statsTable[13+shift]=(void*)count;
 statsTable[14+shift]=(void*)name;statsTable[15+shift]=(void*)request;
 return &stats;
}
extern "C" void *CreateInterface(const char *version, int *) {
    if (std::strcmp(version, "SteamClient018")) return nullptr;
    clientTable[0] = (void *)pipe; clientTable[1] = (void *)release; clientTable[2] = (void *)user;
    clientTable[5]=(void*)getUser;userTable[2]=(void*)steamID;
    clientTable[4] = (void *)releaseUser; clientTable[9] = (void *)getUtils; clientTable[13] = (void *)getStats;
    utilsTable[9] = (void *)getApp;
    statsTable[0] = (void *)request; statsTable[7] = (void *)set; statsTable[8] = (void *)clear;
    statsTable[9] = (void *)get; statsTable[10] = (void *)store; statsTable[12] = (void *)attribute;
    statsTable[14] = (void *)count; statsTable[15] = (void *)name;
    return &client;
}
extern "C" bool Steam_BGetCallback(int, Callback *cb, uint64_t *) {
    if (!pending) return false;
    static Result result; result.game = app(); result.result = (app() == 483 && pending == 1102) ? 5 : (app()==488 ? 2 : 1);result.owner=requestedOwner;
    cb->user = 1; cb->id = pending; cb->data = &result; cb->size = sizeof(result); 
    if(decoy){if(decoy==3)result.owner++;if(decoy==2)result.game+=0x100000000ULL;if(decoy==1)cb->user=2;decoy--;return true;}
    pending = 0; return true;
}
extern "C" void Steam_FreeLastCallback(int) {}
