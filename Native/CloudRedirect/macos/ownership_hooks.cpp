#include "ownership_hooks.h"
#include "runtime_profile.h"
#include "log.h"
#include <atomic>
#include <array>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string>

extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);

namespace OwnershipHooks {
namespace {
using Helper = int(*)(uint32_t,int,void*,uint32_t);
using HasApp = int(*)(void*,int);
static Helper original = nullptr;
static HasApp hasApp = nullptr;
static void** configSlot = nullptr;
static void* target = nullptr;
static std::atomic<bool> installed{false};
static std::atomic<unsigned> repaired{0}, missingOwner{0};

// Verified against Steam ARM64 1792618285, not a copied Windows struct:
// CheckAppOwnership +1444 stores the native owner's account ID at +8;
// +1120, +1468, +1092 store borrowed/family/locked at +31/+35/+2b.
constexpr size_t kSize = 0x38, kOwner = 8;
constexpr size_t kBorrowed = 0x31, kFamilyShared = 0x35, kLocked = 0x2b;

bool selected(uint32_t app) {
    if (!app || app > 0xffffff || !configSlot || !hasApp) return false;
    auto config = __atomic_load_n(configSlot, __ATOMIC_ACQUIRE);
    return config && hasApp(config, static_cast<int>(app));
}

int normalize(uint32_t app, int nativeResult, void* info, uint32_t helperOwner) {
    if (!info || !selected(app)) return original(app,nativeResult,info,helperOwner);
    std::array<unsigned char,kSize> before{};
    std::memcpy(before.data(),info,kSize);
    uint32_t nativeOwner = 0;
    std::memcpy(&nativeOwner,before.data()+kOwner,sizeof(nativeOwner));

    // Steam has already populated its ownership result before this helper is
    // called. Preserve that owner exactly, as upstream Hooks_Package does.
    // Do not substitute a cached loginusers account, hard-coded ID, or current
    // account obtained from macSteam's stale +0x27a CUser layout.
    int result = original(app,nativeResult,info,nativeOwner);
    if (!result || !selected(app)) return result;
    auto bytes = static_cast<unsigned char*>(info);
    std::memcpy(bytes+kOwner,&nativeOwner,sizeof(nativeOwner));
    if (nativeOwner) {
        bytes[kBorrowed] = 0;
        bytes[kFamilyShared] = 0;
        bytes[kLocked] = 0;
    } else {
        // The account is not known yet: retain the native shared/borrowed state
        // and wait for Steam's next normal ownership query. Never invent ID 1.
        bytes[kBorrowed] = before[kBorrowed];
        bytes[kFamilyShared] = before[kFamilyShared];
        bytes[kLocked] = before[kLocked];
        missingOwner++;
    }
    repaired++;
    return result;
}

bool matchingMacSteam(uintptr_t base) {
    auto h = reinterpret_cast<const mach_header_64*>(base);
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64 || h->sizeofcmds > 1024*1024) return false;
    const unsigned char expected[] = {0x35,0x77,0x42,0x6a,0x84,0x37,0x35,0x1b,0x92,0x70,0x0b,0x29,0x32,0x69,0x74,0xdc};
    auto p = reinterpret_cast<const unsigned char*>(h+1), end = p+h->sizeofcmds;
    for (unsigned i=0;i<h->ncmds && p+sizeof(load_command)<=end;i++) {
        auto c = reinterpret_cast<const load_command*>(p);
        if (c->cmdsize < sizeof(load_command) || c->cmdsize > static_cast<size_t>(end-p)) return false;
        if (c->cmd == LC_UUID) return c->cmdsize >= sizeof(uuid_command) && !std::memcmp(reinterpret_cast<const uuid_command*>(p)->uuid,expected,16);
        p += c->cmdsize;
    }
    return false;
}
}

bool Install(uintptr_t steamBase,size_t steamSize) {
    if (installed) return true;
    if (steamSize < RuntimeProfile::familyStore(steamBase)+4 || !RuntimeProfile::UUID(steamBase)) return false;
    if (!RuntimeProfile::Check_ownerStore(steamBase) || !RuntimeProfile::Check_familyStore(steamBase) ||
        !RuntimeProfile::Check_borrowedStore(steamBase) || !RuntimeProfile::Check_lockedStore(steamBase)) return false;
    for (unsigned i=0;i<_dyld_image_count();i++) {
        const char* path = _dyld_get_image_name(i);
        if (!path || !std::string(path).ends_with("/macsteam.dylib")) continue;
        auto base = reinterpret_cast<uintptr_t>(_dyld_get_image_header(i));
        bool legacy=matchingMacSteam(base);
        auto handle = dlopen(path,RTLD_NOLOAD|RTLD_NOW);
        if (!handle) continue;
        auto version = reinterpret_cast<const char*(*)()>(dlsym(handle,"macsteam_version"));
        auto fn = dlsym(handle,"sx_apps_spoof_ownership");
        auto contains = reinterpret_cast<HasApp>(dlsym(handle,"sx_config_has_app"));
        auto config = reinterpret_cast<void**>(dlsym(handle,"sx_config_current"));
        const unsigned char prologue[] = {0xff,0x03,0x03,0xd1,0xf8,0x5f,0x08,0xa9,0xf6,0x57,0x09,0xa9,0xf4,0x4f,0x0a,0xa9};
        auto abi=reinterpret_cast<const unsigned*>(dlsym(handle,"fluent_macsteam_ownership_abi"));
        Dl_info ownerImage{};
        bool owned=abi && *abi==1 && dladdr(fn,&ownerImage) && ownerImage.dli_fbase==reinterpret_cast<void*>(base);
        bool valid = version && std::string(version())=="0.8.2" && fn && contains && config &&
            (owned || (legacy && !std::memcmp(fn,prologue,sizeof(prologue))));
        dlclose(handle);
        if (!valid) continue;
        hasApp=contains; configSlot=config;
        if (DobbyHook(fn,reinterpret_cast<void*>(&normalize),reinterpret_cast<void**>(&original))) {hasApp=nullptr;configSlot=nullptr;return false;}
        target=fn;installed=true;
        LOG("[Ownership] Native owner preservation and selected-game sharing flags installed (verified Steam profile / maintained helper ABI)");
        return true;
    }
    LOG("[Ownership] Compatible macSteam helper unavailable; ownership correction disabled");
    return false;
}
void Remove(){if(installed && DobbyDestroy(target)==0){installed=false;target=nullptr;}}
bool Installed(){return installed.load();}
unsigned Repaired(){return repaired.load();}
unsigned MissingOwner(){return missingOwner.load();}
}
