#include "ticket_hooks.h"
#include "../../Common/native_arch.h"
#include "runtime_settings.h"
#include "runtime_profile.h"
#include "cloud_intercept.h"
#include "log.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <cstring>
#include <atomic>
#include <string>
extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);
namespace TicketHooks {
namespace {
using Extended=int(*)(void*,void*,void*);
using Encrypted=bool(*)(void*,void*,int,uint32_t*);
using Job=bool(*)(void*);
static uintptr_t base=0;static void* ownershipTarget=nullptr;
static Extended extendedOriginal=nullptr;
static Encrypted encryptedOriginal=nullptr;
static Job jobOriginal=nullptr;
static std::atomic<bool> installed{false};
static std::atomic<unsigned> ownershipCount{0},encryptedCount{0},callbackCount{0};
uint64_t identity(void* user){uint64_t id=0;if(user)memcpy(&id,(char*)user+0x242,8);return id;}
uint32_t currentApp(){auto engine=*(void**)(base+RuntimeProfile::Get(base).engineGlobal);return engine?((uint32_t(*)(void*))(base+RuntimeProfile::currentApp(base)))(engine):0;}
const RuntimeSettings::Ticket* find(const RuntimeSettings::Configuration& c,uint32_t app,uint64_t sid){auto i=c.tickets.find(app);return i!=c.tickets.end()&&i->second.steamID==sid?&i->second:nullptr;}
int extended(void* user,void* reader,void* writer){
    // macSteam owns the dispatch detour; wrap its exported handler, avoiding a second detour on the same Steam entry.
    auto data=*(const uint8_t**)reader;int32_t pos=0,end=0;memcpy(&pos,(char*)reader+16,4);memcpy(&end,(char*)reader+24,4);
    if(!data||pos<0||end-pos<12)return extendedOriginal(user,reader,writer);
    uint32_t app=0,cap=0;memcpy(&app,data+pos,4);memcpy(&cap,data+pos+4,4);
    uint64_t sid=user?((uint64_t(*)(void*))(*(void***)user)[10])(user):0;
    auto c=RuntimeSettings::Current();auto t=find(*c,app,sid);
    if(!t||cap<t->ownership.size()||cap>1024*1024)return extendedOriginal(user,reader,writer);
    auto get=(int(*)(void*,void*,int))(base+RuntimeProfile::get(base));uint32_t request[3]{};
    if(!get(reader,request,12))return 0;
    auto put=(void(*)(void*,const void*,int))(base+RuntimeProfile::put(base));
    auto tag=(void(*)(void*,unsigned))(base+RuntimeProfile::tag(base));
    std::vector<uint8_t> buffer(cap);memcpy(buffer.data(),t->ownership.data(),t->ownership.size());
    uint32_t total=(uint32_t)t->ownership.size(),appOffset=t->appOffset,steamOffset=8,sigSize=128;
    tag(writer,11);put(writer,&total,4);put(writer,buffer.data(),(int)cap);put(writer,&appOffset,4);put(writer,&steamOffset,4);put(writer,&t->signature,4);put(writer,&sigSize,4);
    ownershipCount++;return 1;
}
bool encrypted(void* user,void* buffer,int capacity,uint32_t* size){
    auto c=RuntimeSettings::Current();auto t=find(*c,currentApp(),identity(user));
    if(!t)return encryptedOriginal(user,buffer,capacity,size);
    if(!size)return false;*size=(uint32_t)t->encrypted.size();
    if(!buffer||capacity<0||(size_t)capacity<t->encrypted.size())return false;
    memcpy(buffer,t->encrypted.data(),t->encrypted.size());encryptedCount++;return true;
}
bool job(void* j){
    uint32_t app=0;void* user=nullptr;memcpy(&app,(char*)j+RuntimeProfile::Get(base).ticketJobApp,4);memcpy(&user,(char*)j+RuntimeProfile::Get(base).ticketJobUser,8);
    auto c=RuntimeSettings::Current();auto t=find(*c,app,identity(user));
    if(!t)return jobOriginal(j);
    // Use Steam's own asynchronous job completion and callback dispatch. Polling and registered callbacks both see EResult=OK.
    int result=1;((void(*)(void*,const void*,int,int))(base+RuntimeProfile::completeJob(base)))(j,&result,4,154);
    callbackCount++;return true;
}
}
bool Install(uintptr_t b,size_t size){
    if(installed)return true;
    if(size<RuntimeProfile::Get(b).engineGlobal+8||!RuntimeProfile::Check_getETicket(b)||!RuntimeProfile::Check_ticketJob(b)||!RuntimeProfile::Check_completeJob(b)||!RuntimeProfile::Check_currentApp(b)||!RuntimeProfile::Check_put(b)||!RuntimeProfile::Check_get(b)||!RuntimeProfile::Check_tag(b))return false;
    void* target=nullptr;
    for(unsigned i=0;i<_dyld_image_count();++i){const char* p=_dyld_get_image_name(i);if(!p||!std::string(p).ends_with("/macsteam.dylib"))continue;
        auto h=dlopen(p,RTLD_NOLOAD|RTLD_NOW);if(!h)continue;
        auto version=(const char*(*)())dlsym(h,"macsteam_version");
        if(version&&std::string(version())=="0.8.2")target=dlsym(h,"sx_ticket_serve_extended");dlclose(h);break;
    }
    if(!target){LOG("[Tickets] macSteam 0.8.2 handler unavailable; cached ticket consumption disabled");return false;}
    base=b;
    if(DobbyHook(target,(void*)&extended,(void**)&extendedOriginal))return false;
    if(DobbyHook((void*)(b+RuntimeProfile::getETicket(b)),(void*)&encrypted,(void**)&encryptedOriginal)){DobbyDestroy(target);return false;}
    if(DobbyHook((void*)(b+RuntimeProfile::ticketJob(b)),(void*)&job,(void**)&jobOriginal)){DobbyDestroy((void*)(b+RuntimeProfile::getETicket(b)));DobbyDestroy(target);return false;}
    ownershipTarget=target;installed=true;const std::string msg=std::string("[Tickets] ")+FLUENT_ARCH_NAME+" ownership, encrypted ticket, and async completion installed";LOG("%s",msg.c_str());return true;
}
bool Installed(){return installed.load();}
void Remove(){if(!installed)return;DobbyDestroy((void*)(base+RuntimeProfile::ticketJob(base)));DobbyDestroy((void*)(base+RuntimeProfile::getETicket(base)));DobbyDestroy(ownershipTarget);installed=false;}
unsigned OwnershipServed(){return ownershipCount;}unsigned EncryptedServed(){return encryptedCount;}unsigned CallbacksServed(){return callbackCount;}
}
