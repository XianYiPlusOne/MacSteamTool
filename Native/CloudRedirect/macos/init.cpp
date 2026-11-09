// Independent macOS entrypoint. CLI/worker processes never install hooks automatically.
#include "vtable_hook.h"
#include "cloud_hooks.h"
#include "log.h"
#include "xdg.h"
#include "steam_profile.h"
#include "runtime_settings.h"
#include "ticket_hooks.h"
#include "ownership_hooks.h"
#include "onlinefix.h"
#include "manifest_provider.h"
#include <unistd.h>
#include <cstring>
#include <thread>
#include <filesystem>
#include <atomic>
static VtableHook::VtableInfo hooks{};
static VtableHook::CloudEnabledHookInfo cloudEnabled{};
static std::atomic<bool> active{false};
extern "C" const char* CR_GetVersion() { return "mac-port-0.1"; }
extern "C" void CR_SetCrashContext(const char*,const char*,uint32_t) {}
extern "C" void CR_ClearCrashContext() {}
extern "C" void FluentCloudRemoveHooks() {
    if(!active.exchange(false))return;
    RuntimeSettings::Stop();
    ManifestProvider::Remove();
    OnlineFix::Remove();
    OwnershipHooks::Remove();
    TicketHooks::Remove();
    CloudHooks::BeginShutdown();
    VtableHook::RemoveHooks(hooks);
    VtableHook::RemoveCloudEnabledHook(cloudEnabled);
    CloudHooks::ShutdownStorage();
}
extern "C" int FluentCloudInstallHooks() {
    if(active.load())return 1;
    size_t size=0;auto base=VtableHook::FindSteamclient(size);
    if(!base||!CloudHooks::ResolveProtobufHelpers((void*)base,size))return 0;
    auto table=VtableHook::FindTransportVtable(base,size);if(!table)return 0;
    auto remote=VtableHook::FindRemoteStorageVtable(base,size);if(!remote)return 0;
    SteamKvInjector::ResolvedKvAddrs kv{};
    if(!SteamProfile::ResolveKv(base,size,kv))return 0;
    SteamKvInjector::Configure(kv);if(!SteamKvInjector::Init())return 0;
    CloudHooks::SetOriginals(table[5],table[7],table[8]);
    CloudHooks::SetOriginalIsCloudEnabled(remote[24]);
    if(!VtableHook::InstallHooks(table,hooks))return 0;
    if(!VtableHook::InstallCloudEnabledHook(remote,cloudEnabled)){VtableHook::RemoveHooks(hooks);return 0;}
    CloudHooks::InitializeStorage();
    RuntimeSettings::Start();
    CloudHooks::InstallGamesPlayedObserver(base,size);
    TicketHooks::Install(base,size);
    OwnershipHooks::Install(base,size);
    OnlineFix::Install(base,size);
    ManifestProvider::Install();
    active=true;std::atexit(&FluentCloudRemoveHooks);Log::Info("macOS ARM64 cloud RPC / cloud-enabled hooks and KV helpers installed");return 1;
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
