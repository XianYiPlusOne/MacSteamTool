// Native ARM64 adapter. No 32-bit pointers, signal handlers, or executable byte stubs.
#include "live_playtime.h"
#include "runtime_profile.h"
#include "vtable_hook.h"
#include "cloud_intercept.h"
#include "cloud_hooks.h"
#include "metadata_sync.h"
#include "protobuf.h"
#include "log.h"
#include <atomic>
#include <mutex>
#include <deque>
#include <cstring>
extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);
namespace LivePlaytime {
using Writer=uint32_t(*)(void*,void**,int);
static uintptr_t base=0;
static ParseFromArrayFn parse=nullptr;
static void** responseVT=nullptr;
static Writer original=nullptr;
static std::atomic<void*> user{nullptr};
static std::mutex queueMutex;
struct Update{uint32_t account;std::vector<uint8_t> body;};
static std::deque<Update> pending;
static std::atomic<bool> installed{false};
static uint32_t capture(void* u,void** games,int count) {
    uint64_t sid=0;if(u)memcpy(&sid,(char*)u+0x242,8);CloudHooks::ObserveAccount(sid);
    user.store(u,std::memory_order_release);
    return original(u,games,count);
}
bool Resolve(uintptr_t b,size_t size,ParseFromArrayFn p) {
    if(size<RuntimeProfile::writePlaytime(b)+32||!RuntimeProfile::Check_writePlaytime(b))return false;
    responseVT=VtableHook::FindVtableByRTTIName("35CPlayer_GetLastPlayedTimes_Response",b,size);
    if(!responseVT)return false;base=b;parse=p;return true;
}
bool InstallUserCapture() {
    if(installed)return true;if(!base)return false;
    installed=DobbyHook((void*)(base+RuntimeProfile::writePlaytime(base)),(void*)&capture,(void**)&original)==0;
    return installed;
}
void RemoveUserCapture() {
    if(installed)DobbyDestroy((void*)(base+RuntimeProfile::writePlaytime(base)));
    installed=false;user=nullptr;std::lock_guard lock(queueMutex);pending.clear();
}
bool Ready(){return installed&&user.load(std::memory_order_acquire);}
void Apply(const std::vector<uint8_t>& body) {
    auto u=user.load(std::memory_order_acquire);
    if(!u||!parse||!MetadataSync::PlaytimeEnabled()||body.empty()||body.size()>1024*1024)return;
    // CUser identity at +0x242, verified in this build. Never reuse the previous account's writer.
    uint64_t sid=0;memcpy(&sid,(char*)u+0x242,8);
    if((uint32_t)sid!=CloudIntercept::GetAccountId())return;
    // Filter again at the final write boundary: queues may outlive a config change.
    PB::Writer scoped;
    for(auto f:PB::Parse(body.data(),body.size()))if(f.fieldNum==1&&f.wireType==PB::LengthDelimited){
        auto fields=PB::Parse(f.data,f.dataLen);auto app=PB::FindField(fields,1);
        if(app&&CloudIntercept::IsStatsApp((uint32_t)app->varintVal))scoped.WriteBytes(1,f.data,f.dataLen);
    }
    if(!scoped.Size())return;
    auto msg=((void*(*)(void*))responseVT[3])(nullptr);
    if(parse(msg,scoped.Data().data(),(int)scoped.Size())){
        // RepeatedPtrField: count +24, rep +32, rep elements +8 (ARM64).
        int count=0;void* rep=nullptr;memcpy(&count,(char*)msg+24,4);memcpy(&rep,(char*)msg+32,8);
        if(count>0&&count<=4096&&rep)original(u,(void**)((char*)rep+8),count);
    }
    ((void(*)(void*))responseVT[1])(msg);
}
void Queue(const std::vector<uint8_t>& body){if(body.empty()||body.size()>1024*1024)return;std::lock_guard lock(queueMutex);if(pending.size()==64)pending.pop_front();pending.push_back({CloudIntercept::GetAccountId(),body});}
void DrainOnNetThread(){if(!Ready())return;std::deque<Update> work;{std::lock_guard lock(queueMutex);work.swap(pending);}for(auto& update:work)if(update.account==CloudIntercept::GetAccountId())Apply(update.body);}
}
