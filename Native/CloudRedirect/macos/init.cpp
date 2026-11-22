// Independent macOS entrypoint. CLI/worker processes never install hooks automatically.
#include "vtable_hook.h"
#include "steam_kv_injector.h"
#include "cloud_hooks.h"
#include "log.h"
#include "xdg.h"
#include "steam_profile.h"
#include "runtime_settings.h"
#include "manifest_provider.h"
#include <unistd.h>
#include <cstring>
#include <thread>
#include <filesystem>
#include <atomic>
static VtableHook::VtableInfo hooks{};
static std::atomic<bool> active{false};
extern "C" const char* CR_GetVersion() { return "mac-port-0.1"; }
extern "C" void CR_SetCrashContext(const char*,const char*,uint32_t) {}
extern "C" void CR_ClearCrashContext() {}
extern "C" void FluentCloudRemoveHooks() {
    if(!active.exchange(false))return;
    RuntimeSettings::Stop();
    ManifestProvider::Remove();
    CloudHooks::BeginShutdown();
    VtableHook::RemoveHooks(hooks);
    CloudHooks::ShutdownStorage();
}
extern "C" int FluentCloudInstallHooks() {
    if(active.load())return 1;
    size_t size=0;auto base=VtableHook::FindSteamclient(size);
    if(!base||!CloudHooks::ResolveProtobufHelpers((void*)base,size))return 0;
    auto table=VtableHook::FindTransportVtable(base,size);if(!table)return 0;
    SteamKvInjector::ResolvedKvAddrs kv{};
    if(!SteamProfile::ResolveKv(base,size,kv))return 0;
    SteamKvInjector::Configure(kv);if(!SteamKvInjector::Init())return 0;
    CloudHooks::SetOriginal(table[5]);
    if(!VtableHook::InstallHooks(table,hooks))return 0;
    CloudHooks::InitializeStorage();
    RuntimeSettings::Start();
    CloudHooks::InstallGamesPlayedObserver(base,size);
    ManifestProvider::Install();
    active=true;std::atexit(&FluentCloudRemoveHooks);Log::Info("macOS ARM64 runtime extension initialized");return 1;
}
__attribute__((constructor)) static void Start() {
    const char* process=getprogname();
    if(!process||strcmp(process,"steam_osx"))return;
    std::thread([]{
        std::filesystem::create_directories(XdgConfigHome()+"/CloudRedirect");Log::Init();
        if(access((XdgConfigHome()+"/CloudRedirect/disable").c_str(),F_OK)==0)return;
        for(int i=0;i<120;i++){
            size_t size=0;if(VtableHook::FindSteamclient(size)){FluentCloudInstallHooks();return;}
            usleep(250000);
        }
    }).detach();
}
