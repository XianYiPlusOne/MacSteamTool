// Runs real macSteam code and the new wrapper in a disposable process. Never
// creates a Steam IPC pipe, launches a game, or opens save/achievement files.
#include "ownership_hooks.h"
#include "runtime_profile.h"
#include <array>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <vector>

using Info=std::array<unsigned char,0x38>;
static void check(bool ok,const char* text){if(!ok){fprintf(stderr,"FAIL: %s\n",text);std::exit(1);}}
static void owner(Info& info,uint32_t value){std::memcpy(info.data()+8,&value,4);}
static uint32_t owner(const Info& info){uint32_t v=0;std::memcpy(&v,info.data()+8,4);return v;}

int main(int argc,char**argv){
    check(argc==4,"steamclient, macsteam and new isolated directory required");
    check(!std::filesystem::exists(argv[3]),"fixture directory must be new");
    std::filesystem::create_directories(argv[3]);
    const auto configPath=std::string(argv[3])+"/config.yaml";
    std::ofstream(configPath)<<"Apps:\n  - 4348910\n";
    setenv("MACSTEAM_CONFIG",configPath.c_str(),1);
    setenv("MACSTEAM_LOG_LEVEL","0",1);
    auto steam=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);check(steam,"load real ARM64 Steam binary");
    auto mac=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);check(mac,"load real macSteam 0.8.2");
    auto helper=reinterpret_cast<int(*)(uint32_t,int,void*,uint32_t)>(dlsym(mac,"sx_apps_spoof_ownership"));
    auto load=reinterpret_cast<int(*)(const char*,void*)>(dlsym(mac,"sx_config_load"));
    auto freeConfig=reinterpret_cast<void(*)(void*)>(dlsym(mac,"sx_config_free"));
    auto ready=reinterpret_cast<void(*)()>(dlsym(mac,"sx_apps_force_ready"));
    auto slot=reinterpret_cast<void**>(dlsym(mac,"sx_config_current"));
    check(helper&&load&&freeConfig&&ready&&slot,"macSteam helper exports");
    std::vector<unsigned char> cfg(2*1024*1024);
    check(load(configPath.c_str(),cfg.data())==0,"load fixture config using macSteam parser");
    *slot=cfg.data();
    Info native{};native.fill(0x5a);owner(native,24680);native[0x31]=native[0x35]=native[0x2b]=1;
    auto unready=native;check(helper(4348910,0,unready.data(),0)==0&&unready==native,"unready helper leaves native failure untouched");
    ready();auto broken=native;check(helper(4348910,1,broken.data(),0)==1&&owner(broken)==1,"reproduce ID-1 regression in installed macSteam");
    Dl_info image{};check(dladdr(dlsym(steam,"CreateInterface"),&image)&&image.dli_fbase,"resolve actual Steam image");
    auto base=reinterpret_cast<uintptr_t>(image.dli_fbase);
    check(!OwnershipHooks::Install(base,128),"unsupported image size refused");
    check(OwnershipHooks::Install(base,RuntimeProfile::familyStore(base)+4)&&OwnershipHooks::Installed(),"install guarded wrapper on macSteam export");
    auto repaired=native;check(helper(4348910,1,repaired.data(),0)==1,"selected helper keeps result");
    check(owner(repaired)==24680&&!repaired[0x31]&&!repaired[0x35]&&!repaired[0x2b],"native owner preserved and sharing flags cleared");
    auto expected=broken;owner(expected,24680);expected[0x31]=expected[0x35]=expected[0x2b]=0;
    check(repaired==expected,"all remaining ownership fields identical to original macSteam behavior");
    auto wrongAccount=native;check(helper(4348910,1,wrongAccount.data(),13579)==1&&owner(wrongAccount)==24680,"stale helper account cannot replace Steam's owner");
    auto switched=native;owner(switched,97531);check(helper(4348910,1,switched.data(),24680)==1&&owner(switched)==97531,"subsequent account is derived from new native query");
    auto other=native;check(helper(4348911,0,other.data(),0)==0&&other==native,"unselected failure and complete record unchanged");
    check(helper(4348911,1,other.data(),0)==1&&other==native,"unselected owned/shared result unchanged");
    auto unknown=native;owner(unknown,0);check(helper(4348910,0,unknown.data(),0)==1&&owner(unknown)==0,"unknown owner does not become account 1");
    check(unknown[0x31]==1&&unknown[0x35]==1&&unknown[0x2b]==1&&OwnershipHooks::MissingOwner()==1,"unknown-account state deferred");
    check(helper(4348910,0,nullptr,0)==1,"null output keeps upstream result");
    *slot=nullptr;other=native;check(helper(4348910,1,other.data(),0)==1&&other==native,"hot disable removes scope");
    *slot=cfg.data();OwnershipHooks::Remove();check(!OwnershipHooks::Installed(),"wrapper uninstalls");
    broken=native;check(helper(4348910,1,broken.data(),0)==1&&owner(broken)==1,"original behavior restored after uninstall");
    *slot=nullptr;freeConfig(cfg.data());
    puts("PASS: actual macSteam ID-1 reproduction and correction, native-owner retention, current-query account switch, three sharing flags, byte-exact unrelated fields, unselected apps, unknown account, null result, hot disable, profile rejection and clean uninstall; no Steam IPC or game data access.");
}
