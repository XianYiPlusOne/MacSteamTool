// Private process only: verifies actual image/profile/hook installation. No Steam
// IPC, network, game process, save files or live client memory are accessed.
#include "onlinefix.h"
#include "onlinefix_profile.h"
#include "dobby.h"
#include "runtime_settings.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <array>
#include <string>
static void check(bool ok,const char* what){if(!ok){fprintf(stderr,"FAIL: %s\n",what);std::exit(1);}}
extern "C" __attribute__((naked)) void spawnStop(){asm volatile("add sp, sp, #0x4b0\nldp x29,x30,[sp,#0x50]\nldp x20,x19,[sp,#0x40]\nldp x22,x21,[sp,#0x30]\nldp x24,x23,[sp,#0x20]\nldp x26,x25,[sp,#0x10]\nldp x28,x27,[sp],#0x60\nmov w0,#0\nret");}
extern "C" __attribute__((naked)) void envStop(){asm volatile("add sp, sp, #0x510\nldp x29,x30,[sp,#0x50]\nldp x20,x19,[sp,#0x40]\nldp x22,x21,[sp,#0x30]\nldp x24,x23,[sp,#0x20]\nldp x26,x25,[sp,#0x10]\nldp x28,x27,[sp],#0x60\nmov w0,#0\nret");}
int main(int argc,char**argv){
    check(argc==2&&getenv("FLUENT_CLOUD_ROOT")&&getenv("MACSTEAM_CONFIG"),"steamclient path and isolated roots required");
    RuntimeSettings::Reload();
    auto handle=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);check(handle,"load real Steam image in isolated process");
    Dl_info image{};check(dladdr(dlsym(handle,"CreateInterface"),&image)&&image.dli_fbase,"resolve Steam image");
    uintptr_t base=reinterpret_cast<uintptr_t>(image.dli_fbase);
    check(!OnlineFix::Install(base,32),"short profile refused");
    check(OnlineFixProfile::Match(base,0xa72000),"UUID and four exact code sites match");
    std::array<unsigned char,32> spawn{},env{},utils{},result{};
    memcpy(spawn.data(),(void*)(base+OnlineFixProfile::spawn),32);memcpy(env.data(),(void*)(base+OnlineFixProfile::environment),32);
    memcpy(utils.data(),(void*)(base+OnlineFixProfile::utils),32);memcpy(result.data(),(void*)(base+OnlineFixProfile::utilsResult),32);
    check(OnlineFix::Install(base,0xa72000)&&OnlineFix::Installed(),"four native hooks installed");
    check(!memcmp((void*)(base+0x839048),utils.data()+24,8),"adjacent IPC switch target remains intact");
    for(auto command:{"game.exe -onlinefix","\"game path.exe\" \"-onlinefix\"","game.exe\t-onlinefix -windowed"})check(OnlineFix::HasOption(command),"exact option accepted");
    for(auto command:{"game.exe --onlinefix","game.exe -onlinefix=false","game.exe -onlinefix-extra","\"folder -onlinefix\"","game.exe"})check(!OnlineFix::HasOption(command),"substring is not an option");
    uint64_t id=4348910;check(!OnlineFix::RewriteLaunch(id,"-onlinefix",false)&&id==4348910,"unmanaged launch unchanged");
    check(OnlineFix::RewriteLaunch(id,"-onlinefix",true)&&id==480&&OnlineFix::ActiveApp()==4348910,"explicit managed launch selects lobby identity");
    uint64_t overlay=480;OnlineFix::RestoreOverlay(id,overlay);check(overlay==4348910&&id==480,"real overlay with native lobby identity");
    check(OnlineFix::RestoreAppID(480)==4348910&&OnlineFix::RestoreAppID(100)==100,"only active alias GetAppID remapped");
    id=uint64_t(1)<<40;check(!OnlineFix::RewriteLaunch(id,"-onlinefix",true)&&id==(uint64_t(1)<<40),"shortcuts preserved");
    OnlineFix::ObserveRunning(true);OnlineFix::ObserveRunning(false);check(!OnlineFix::ActiveApp(),"mode clears on game exit");
    // Execute the actual entry instrumentation, then stop at +32 before any
    // Steam internals or process creation. No live client is involved.
    void* unused=nullptr;check(!DobbyHook((void*)(base+OnlineFixProfile::spawn+32),(void*)&spawnStop,&unused),"install private spawn stop");
    check(!DobbyHook((void*)(base+OnlineFixProfile::environment+32),(void*)&envStop,&unused),"install private env stop");
    using Spawn=int(*)(void*,const char*,const char*,const char*,uint64_t*,void*,void*,void*);
    id=100;reinterpret_cast<Spawn>(base+OnlineFixProfile::spawn)(nullptr,"fixture.exe","ordinary","/tmp",&id,nullptr,nullptr,nullptr);
    check(id==100&&!OnlineFix::ActiveApp(),"real spawn instrumentation preserves ordinary launch");
    id=4348910;reinterpret_cast<Spawn>(base+OnlineFixProfile::spawn)(nullptr,"fixture.exe","fixture.exe -onlinefix","/tmp",&id,nullptr,nullptr,nullptr);
    check(id==480&&OnlineFix::ActiveApp()==4348910,"real spawn ARM64 argument registers enter opt-in mode");overlay=480;
    using Env=int(*)(void*,uint64_t*,void*,void*,uint64_t*,void*,void*,void*);
    reinterpret_cast<Env>(base+OnlineFixProfile::environment)(nullptr,&id,nullptr,nullptr,&overlay,nullptr,nullptr,nullptr);
    check(id==480&&overlay==4348910,"real ARM64 environment registers preserve lobby and restore overlay");
    DobbyDestroy((void*)(base+OnlineFixProfile::spawn+32));DobbyDestroy((void*)(base+OnlineFixProfile::environment+32));OnlineFix::Remove();
    check(!OnlineFix::Installed()&&!memcmp(spawn.data(),(void*)(base+OnlineFixProfile::spawn),32)&&!memcmp(env.data(),(void*)(base+OnlineFixProfile::environment),32)&&!memcmp(utils.data(),(void*)(base+OnlineFixProfile::utils),32)&&!memcmp(result.data(),(void*)(base+OnlineFixProfile::utilsResult),32),"all original code restored");
    puts("PASS: pinned Steam profile, four hook install/restore, adjacent switch integrity, exact option parsing, game scope, lobby/overlay/GetAppID identity, exit cleanup and real ARM64 entry instrumentation. No game, IPC or save access.");
}
