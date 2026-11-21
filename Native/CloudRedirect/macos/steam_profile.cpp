// UUID-scoped, reviewed addresses shared by all native Steam adapters.
#include "steam_profile.h"
#include "runtime_profile.h"
bool SteamProfile::ResolveKv(uintptr_t base,size_t size,SteamKvInjector::ResolvedKvAddrs& out) {
    const auto& profile=RuntimeProfile::Get(base);
    if(!profile.build || size<profile.engineGlobal+8)return false;
    if(!RuntimeProfile::Check_getAppInfo(base))return false;
    out.getAppInfo=base+RuntimeProfile::getAppInfo(base);
    if(!RuntimeProfile::Check_getSection(base))return false;
    out.getSection=base+RuntimeProfile::getSection(base);
    if(!RuntimeProfile::Check_readConfigU64(base))return false;
    out.readConfigU64=base+RuntimeProfile::readConfigU64(base);
    if(!RuntimeProfile::Check_kvFindKey(base))return false;
    out.kvFindKey=base+RuntimeProfile::kvFindKey(base);
    if(!RuntimeProfile::Check_kvGetUint64(base))return false;
    out.kvGetUint64=base+RuntimeProfile::kvGetUint64(base);
    if(!RuntimeProfile::Check_kvGetInt(base))return false;
    out.kvGetInt=base+RuntimeProfile::kvGetInt(base);
    if(!RuntimeProfile::Check_kvSetUint64(base))return false;
    out.kvSetUint64=base+RuntimeProfile::kvSetUint64(base);
    if(!RuntimeProfile::Check_kvSetInt(base))return false;
    out.kvSetInt=base+RuntimeProfile::kvSetInt(base);
    if(!RuntimeProfile::Check_kvSetString(base))return false;
    out.kvSetString=base+RuntimeProfile::kvSetString(base);
    out.globalEnginePtrPtr=reinterpret_cast<void**>(base+profile.engineGlobal);
    out.appInfoCacheOffset=profile.appInfoCache;
    return true;
}
