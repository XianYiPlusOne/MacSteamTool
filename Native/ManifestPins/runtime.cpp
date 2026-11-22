#include "pins.h"
#include "../AppSupportDirectory.h"
#include "../SteamIntegration/steam_profiles.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <unistd.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <filesystem>
#include <fstream>
extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);
namespace {
using ReadManifest=bool(*)(void*,void*,const char*);
struct Runtime {
    ReadManifest original=nullptr;void* target=nullptr;
    std::shared_ptr<const FluentPins::Pins> pins{std::make_shared<const FluentPins::Pins>()};
    std::mutex installation;std::atomic<bool> stopping{false};std::thread watcher;
};
Runtime& runtime(){static auto* value=new Runtime;return *value;}
std::string path(const char* key,const char* fallback){const char* env=getenv(key);if(env && *env=='/')return env;const char* home=getenv("HOME");return std::string(home?home:"")+fallback;}
void status(const std::string& value){
    try{
        const char* configured = getenv("FLUENT_PINS_STATUS");
        const char* home = getenv("HOME");
        auto file = configured && configured[0] == '/' ? std::string(configured) : MacSteamToolDataDirectory(home ? home : "") + "/manifest-pins.log";
        std::filesystem::create_directories(std::filesystem::path(file).parent_path());
        std::ofstream(file,std::ios::app)<<"PID "<<getpid()<<" · "<<value<<'\n';
    }catch(...){}
}
bool hook(void* state,void* root,const char* branch){
    // Verified ARM64 depot selection: depot at +0, manifest gid at +8, disk size at +16.
    // Public branch only: encrypted/private beta selections keep Steam's original behavior.
    bool result=runtime().original(state,root,branch);
    if(!state || !branch || std::strcmp(branch,"public"))return result;
    auto current=std::atomic_load(&runtime().pins);uint32_t depot;std::memcpy(&depot,state,4);
    auto found=current->find(depot);if(found==current->end())return result;
    // Preserve the original validity check; this extension does not synthesize depot membership.
    if(!result)return result;
    std::memcpy(static_cast<char*>(state)+8,&found->second.gid,8);
    std::memcpy(static_cast<char*>(state)+16,&found->second.size,8);
    return true;
}
}
uintptr_t FluentPins::FindClient(){
    for(uint32_t i=0;i<_dyld_image_count();++i){
        const char* name=_dyld_get_image_name(i);if(!name || !std::string_view(name).ends_with("/steamclient.dylib"))continue;
        auto h=reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if(h->magic!=MH_MAGIC_64 || h->cputype!=CPU_TYPE_ARM64)return 0;
        return reinterpret_cast<uintptr_t>(h);
    }return 0;
}
extern "C" void FluentPinsReload(){
    auto next=FluentPins::Read(path("FLUENT_PINS_CONFIG","/Library/Application Support/macsteam/config.yaml"),path("FLUENT_PINS_CACHE","/Library/Application Support/Steam/depotcache"));
    if(*std::atomic_load(&runtime().pins)!=next)status("verified cached pins refreshed: "+std::to_string(next.size()));
    std::atomic_store(&runtime().pins,std::make_shared<const FluentPins::Pins>(std::move(next)));
}
extern "C" unsigned FluentPinsCount(){return static_cast<unsigned>(std::atomic_load(&runtime().pins)->size());}
extern "C" int FluentPinsInstall(){
    auto& r=runtime();
    std::lock_guard<std::mutex> lock(r.installation);if(r.target)return 1;
    auto base=FluentPins::FindClient();if(!base)return 0;
    if(!RuntimeProfile::Check_readManifest(base)){status("unsupported Steam build or existing detour; pins disabled");return -1;}
    FluentPinsReload();
    if(DobbyHook(reinterpret_cast<void*>(base+RuntimeProfile::readManifest(base)),reinterpret_cast<void*>(&hook),reinterpret_cast<void**>(&r.original))!=0){status("detour installation failed");return -1;}
    r.target=reinterpret_cast<void*>(base+RuntimeProfile::readManifest(base));
    // Register after Dobby's registry and code writer have been initialized.
    // A dylib destructor alone runs after their C++ destructors on real Steam
    // exit, so looking up the detour there can access the freed registry.
    std::atexit(&FluentPinsRemove);
    status("manifest pin hook installed; verified cached pins="+std::to_string(FluentPinsCount()));return 1;
}
extern "C" void FluentPinsRemove(){
    auto& r=runtime();r.stopping=true;if(r.watcher.joinable())r.watcher.join();
    std::lock_guard<std::mutex> lock(r.installation);
    if(r.target && DobbyDestroy(r.target)==0){r.target=nullptr;std::atomic_store(&r.pins,std::make_shared<const FluentPins::Pins>());status("manifest pin hook removed");}
}
__attribute__((constructor)) static void start(){
    if(!getprogname() || std::strcmp(getprogname(),"steam_osx"))return;
    runtime().watcher=std::thread([]{
        for(int i=0;i<120 && !runtime().stopping;++i){
            int result=FluentPinsInstall();if(result<0)return;
            if(result>0){while(!runtime().stopping){std::this_thread::sleep_for(std::chrono::seconds(1));if(!runtime().stopping)FluentPinsReload();}return;}
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }
    });
}
__attribute__((destructor)) static void stop(){FluentPinsRemove();}
