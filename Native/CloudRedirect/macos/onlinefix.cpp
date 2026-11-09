#include "onlinefix.h"
#include "onlinefix_profile.h"
#include "runtime_settings.h"
#include "log.h"
#include "dobby.h"
#include <atomic>
#include <cstring>
#include <cctype>
#include <mutex>

namespace OnlineFix {
namespace {
std::atomic<bool> installed{false}, observedAlias{false};
std::atomic<uint32_t> activeApp{0};
uintptr_t image=0;
thread_local uintptr_t utilsStack=0;
std::mutex installMutex;
void spawn(void*,DobbyRegisterContext* ctx) {
    auto id=reinterpret_cast<uint64_t*>(ctx->general.regs.x4);if(!id)return;
    auto config=RuntimeSettings::Current();auto real=static_cast<uint32_t>(*id);
    if(RewriteLaunch(*id,reinterpret_cast<const char*>(ctx->general.regs.x2),config->managedApps.count(real)))
        LOG("[OnlineFix] Explicit launch option enabled for app %u; lobby identity 480",real);
}
void environment(void*,DobbyRegisterContext* ctx) {
    auto game=reinterpret_cast<const uint64_t*>(ctx->general.regs.x1);
    auto overlay=reinterpret_cast<uint64_t*>(ctx->general.regs.x4);
    if(game&&overlay&&game!=overlay)RestoreOverlay(*game,*overlay);
}
void utils(void*,DobbyRegisterContext* ctx) {
    // Mark only the GetAppID branch, at a straight-line site with enough room.
    // Never overwrite the adjacent switch target at 0x839048.
    utilsStack=ActiveApp()?ctx->sp:0;
}
void utilsResult(void*,DobbyRegisterContext* ctx) {
    if(utilsStack&&utilsStack==ctx->sp){utilsStack=0;ctx->general.regs.x0=RestoreAppID(static_cast<uint32_t>(ctx->general.regs.x0));}
}
}
bool HasOption(const char* command) {
    if(!command)return false;
    size_t length=strnlen(command,32768);if(length==32768)return false;
    std::string token;char quote=0;
    for(size_t i=0;i<=length;i++) {
        char c=command[i];
        if(c=='\\'&&quote&&i+1<length&&(command[i+1]==quote||command[i+1]=='\\')) {token+=command[++i];continue;}
        if((c=='\"'||c=='\'')&&(!quote||quote==c)){quote=quote?0:c;continue;}
        if(!c||(!quote&&std::isspace(static_cast<unsigned char>(c)))) {
            if(token=="-onlinefix"&&!quote)return true;
            token.clear();
        } else token+=c;
    }
    return false;
}
bool RewriteLaunch(uint64_t& id,const char* command,bool managed) {
    if(!id||id>0xffffff)return false;
    if(id!=480&&managed&&HasOption(command)) {
        activeApp=static_cast<uint32_t>(id);observedAlias=false;id=480;return true;
    }
    activeApp=0;observedAlias=false;return false;
}
void RestoreOverlay(uint64_t game,uint64_t& overlay) {auto app=ActiveApp();if(app&&game==480&&overlay==480)overlay=app;}
uint32_t RestoreAppID(uint32_t native) {auto app=ActiveApp();return native==480&&app?app:native;}
void ObserveRunning(bool present) {if(present&&ActiveApp())observedAlias=true;else if(!present&&observedAlias.exchange(false))activeApp=0;}
uint32_t ActiveApp(){return activeApp.load();}
bool Installed(){return installed.load();}
bool Install(uintptr_t base,size_t size) {
    std::lock_guard lock(installMutex);
    if(installed)return true;
    if(!OnlineFixProfile::Match(base,size))return false;
    const uintptr_t offsets[]={OnlineFixProfile::spawn,OnlineFixProfile::environment,OnlineFixProfile::utils,OnlineFixProfile::utilsResult};
    dobby_instrument_callback_t callbacks[]={spawn,environment,utils,utilsResult};
    for(unsigned i=0;i<4;i++)if(DobbyInstrument(reinterpret_cast<void*>(base+offsets[i]),callbacks[i])) {
        for(unsigned j=0;j<i;j++)DobbyDestroy(reinterpret_cast<void*>(base+offsets[j]));
        LOG("[OnlineFix] Hook installation failed; mode remains unavailable");return false;
    }
    image=base;installed=true;LOG("[OnlineFix] Guarded -onlinefix launch, overlay and GetAppID hooks installed");return true;
}
void Remove(){std::lock_guard lock(installMutex);if(!installed)return;for(auto offset:{OnlineFixProfile::spawn,OnlineFixProfile::environment,OnlineFixProfile::utils,OnlineFixProfile::utilsResult})DobbyDestroy(reinterpret_cast<void*>(image+offset));installed=false;activeApp=0;observedAlias=false;}
}
