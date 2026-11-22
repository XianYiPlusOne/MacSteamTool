#include "gamesplayed_hook.h"
#include "multiplayer_presence.h"
#include "runtime_profile.h"
#include "runtime_settings.h"
#include "stats_handlers.h"
#include "metadata_sync.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "live_playtime.h"
#include "protobuf.h"
#include "log.h"
#include <atomic>
#include <cstring>
#include <libproc.h>
#include <algorithm>
#include <ctime>
#include <unordered_set>
extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);
namespace GamesPlayedHook {
using Send=bool(*)(void*,void*);
static SerializeBodyFn serialize=nullptr;
static Send original=nullptr;
static uintptr_t base=0;
static std::atomic<bool> installed{false};
static std::atomic<unsigned> observed{0},rewritten{0},tokenRequests{0};
static std::atomic<unsigned> sent{0},failed{0};
static std::atomic<uint32_t> lastApp{0};
static std::atomic<uint64_t> lastGameID{0},lastAttemptedGameID{0};
static std::atomic<uint64_t> lastSentAt{0};
void SetSerializer(SerializeBodyFn fn){serialize=fn;}
static void copy(PB::Writer& out,const PB::Field& f){switch(f.wireType){case PB::Varint:out.WriteVarint(f.fieldNum,f.varintVal);break;case PB::Fixed64:out.WriteFixed64(f.fieldNum,f.varintVal);break;case PB::Fixed32:out.WriteFixed32(f.fieldNum,(uint32_t)f.varintVal);break;case PB::LengthDelimited:out.WriteBytes(f.fieldNum,f.data,f.dataLen);break;}}
static bool windowsProcess(uint64_t pid){
    if(!pid||pid>INT32_MAX)return false;char path[PROC_PIDPATHINFO_MAXSIZE]{};
    if(proc_pidpath((int)pid,path,sizeof(path))<=0)return false;
    std::string p=path;std::transform(p.begin(),p.end(),p.begin(),[](unsigned char c){return std::tolower(c);});
    return p.ends_with(".exe")||((p.find("/notproton/")!=std::string::npos||p.find("/crossover/")!=std::string::npos)&&p.find("wine")!=std::string::npos);
}
static std::vector<uint8_t> platformBody(const std::vector<uint8_t>& input){
    PB::Writer out;
    for(const auto& f:PB::Parse(input.data(),input.size())){
        if(f.fieldNum!=1||f.wireType!=PB::LengthDelimited){copy(out,f);continue;}
        auto fields=PB::Parse(f.data,f.dataLen);bool windows=false;
        for(const auto& g:fields){
            if(g.fieldNum==9)windows|=windowsProcess(g.varintVal);
            if(g.fieldNum==32&&g.wireType==PB::LengthDelimited){auto ps=PB::Parse(g.data,g.dataLen);if(auto pid=PB::FindField(ps,1))windows|=windowsProcess(pid->varintVal);}
        }
        if(!windows){copy(out,f);continue;}
        PB::Writer game;for(const auto& g:fields)if(g.fieldNum!=25)copy(game,g);
        game.WriteVarint(25,20);out.WriteSubmessage(1,game);
    }
    return out.Data();
}
bool ApplyAccessTokens(uint32_t message,const std::vector<uint8_t>& input,std::vector<uint8_t>& output){
    auto c=RuntimeSettings::Current();if(message!=8903||c->accessTokens.empty())return false;
    PB::Writer out;bool changed=false;
    for(const auto& f:PB::Parse(input.data(),input.size())){
        // CMsgClientPICSProductInfoRequest.apps = 2. Package tokens and all
        // unrelated fields retain their original values.
        if(f.fieldNum!=2||f.wireType!=PB::LengthDelimited){copy(out,f);continue;}
        auto fields=PB::Parse(f.data,f.dataLen);auto id=PB::FindField(fields,1);
        if(!id||id->wireType!=PB::Varint||id->varintVal>UINT32_MAX){copy(out,f);continue;}
        auto found=c->accessTokens.find((uint32_t)id->varintVal);
        if(found==c->accessTokens.end()){copy(out,f);continue;}
        PB::Writer app;for(const auto& value:fields)if(value.fieldNum!=2)copy(app,value);
        app.WriteVarint(2,found->second);out.WriteSubmessage(2,app);changed=true;
    }
    if(changed)output=out.Data();return changed;
}
static bool filterGameList(std::vector<PB::Field>& fields,std::vector<uint8_t>& output){
    bool changed=MultiplayerPresence::PreferGames(fields);
    auto c=RuntimeSettings::Current();
    if(c->presence=="unchanged"||c->presenceApps.empty()){
        if(changed){
            PB::Writer out;
            for(const auto& field:fields)copy(out,field);
            output=out.Data();
        }
        return changed;
    }
    size_t top=fields.size();std::unordered_set<uint64_t> running;
    for(size_t i=0;i<fields.size();i++)if(fields[i].fieldNum==1&&fields[i].wireType==PB::LengthDelimited){
        top=i;auto gameFields=PB::Parse(fields[i].data,fields[i].dataLen);auto id=PB::FindField(gameFields,2);
        if(id&&id->wireType==PB::Fixed64)running.insert(id->varintVal);
    }
    // Match the original's most-recent-game rule. Never collapse other entries
    // or borrow a shortcut that is already being played in its own right.
    uint64_t alias=0;
    if(c->presenceAccount==CloudIntercept::GetAccountId())for(auto id:c->presenceShortcuts)if(!running.count(id)){alias=id;break;}
    if(!alias&&!running.count(480))alias=480;
    PB::Writer out;
    for(size_t i=0;i<fields.size();i++){
        auto& f=fields[i];
        if(f.fieldNum!=1||f.wireType!=PB::LengthDelimited){copy(out,f);continue;}
        auto sub=PB::Parse(f.data,f.dataLen);auto game=PB::FindField(sub,2);
        // Never reinterpret a shortcut/mod GameID as an ordinary app.
        if(!game||game->wireType!=PB::Fixed64||game->varintVal>0xffffff){copy(out,f);continue;}
        uint32_t id=(uint32_t)game->varintVal;
        auto found=c->presenceApps.find(id);if(found==c->presenceApps.end()){copy(out,f);continue;}
        if(c->presence=="none"){changed=true;continue;}
        if(i!=top||!alias||id==480){copy(out,f);continue;}
        changed=true;
        // The compatibility entry carries the original title but is explicitly
        // a shortcut (preferred) or Spacewar. Other entries and their owners
        // are untouched; this is not the upstream blanket owner-ID mask.
        PB::Writer rewritten;for(auto& sf:sub)if(sf.fieldNum!=2&&sf.fieldNum!=7&&sf.fieldNum!=12)copy(rewritten,sf);
        auto name=found->second;auto extra=PB::FindField(sub,7);
        if(name.empty()&&extra&&extra->wireType==PB::LengthDelimited)name.assign((const char*)extra->data,extra->dataLen);
        rewritten.WriteFixed64(2,alias);rewritten.WriteString(7,name.empty()?"App "+std::to_string(id):name);out.WriteSubmessage(1,rewritten);
    }
    if(changed)output=out.Data();return changed;
}
bool FilterPresence(uint32_t message,const std::vector<uint8_t>& input,std::vector<uint8_t>& output){
    if(message!=742&&message!=5410&&message!=715)return false;
    auto fields=PB::Parse(input.data(),input.size());
    return filterGameList(fields,output);
}
bool SuppressRichPresence(uint32_t appID){
    auto c=RuntimeSettings::Current();return c->presence=="none"&&c->presenceApps.count(appID);
}
static bool send(void* cm,void* wrapper){
    if(!wrapper||!serialize)return original(cm,wrapper);
    uint32_t message=0;memcpy(&message,(char*)wrapper+40,4);message&=0x7fffffff;
    bool games=message==742||message==715||message==5410;
    if(!games&&message!=5466&&message!=7501&&message!=8903)return original(cm,wrapper);
    void* body=nullptr;memcpy(&body,(char*)wrapper+56,8);if(!body)return original(cm,wrapper);
    void* header=nullptr;memcpy(&header,(char*)wrapper+48,8);
    if(header){size_t hn=0;auto hb=serialize(header,&hn);auto fields=PB::Parse(hb,hn);auto sid=PB::FindField(fields,1);if(sid)CloudHooks::ObserveAccount(sid->varintVal);}
    size_t len=0;auto bytes=serialize(body,&len);std::vector<uint8_t> input;if(bytes)input.assign(bytes,bytes+len);
    if(games){
        observed++;
    }
    if(games&&MetadataSync::PlaytimeEnabled()){
        auto platformInput=platformBody(input);auto ended=StatsHandlers::ObserveGamesPlayed(platformInput.data(),platformInput.size());
        if(!ended.empty())LivePlaytime::Queue(StatsHandlers::BuildLastPlayedNotificationBody(ended).Data());
    }
    // Read native stats after Steam has committed its local file (post-send path).
    std::vector<PB::Field> gameList;
    std::vector<uint8_t> filtered;
    bool changed=false;
    if(games){
        gameList=PB::Parse(input.data(),input.size());
        changed=filterGameList(gameList,filtered);
    }
    if(message==7501){
        void* header=nullptr;memcpy(&header,(char*)wrapper+48,8);size_t headerLen=0;auto raw=header?serialize(header,&headerLen):nullptr;
        auto fields=PB::Parse(raw,headerLen);auto route=PB::FindField(fields,3);
        if(route&&route->varintVal<=UINT32_MAX&&SuppressRichPresence((uint32_t)route->varintVal))changed=true;
    }
    if(message==7501&&changed){rewritten++;return true;}
    void* clone=nullptr;
    if(changed){
        auto vt=*(void***)body;clone=((void*(*)(void*))vt[3])(nullptr);
        auto parse=(int(*)(void*,const void*,int))(base+RuntimeProfile::parse(base));
        static const uint8_t empty=0;
        if(!clone||!parse(clone,filtered.empty()?&empty:filtered.data(),(int)filtered.size())){if(clone)((void(*)(void*))vt[1])(clone);clone=nullptr;if(games)failed++;}
        else {memcpy((char*)wrapper+56,&clone,8);if(message==8903)tokenRequests++;else rewritten++;}
    }
    uint32_t sourceApp=0;uint64_t outgoingGameID=0;
    if(games&&clone){
        auto config=RuntimeSettings::Current();size_t sourceIndex=0,inputCount=0;
        for(auto& f:gameList)if(f.fieldNum==1&&f.wireType==PB::LengthDelimited){
            auto fields=PB::Parse(f.data,f.dataLen);auto id=PB::FindField(fields,2);
            if(id&&id->wireType==PB::Fixed64&&id->varintVal<=0xffffff&&config->presenceApps.count((uint32_t)id->varintVal)){sourceApp=(uint32_t)id->varintVal;sourceIndex=inputCount;}
            inputCount++;
        }
        if(!sourceApp && inputCount)sourceIndex=inputCount-1;
        // Read back the typed protobuf being handed to Steam, not the original
        // AppID or our intended title. Zero denotes a removed (hidden) entry.
        size_t size=0,outputCount=0;auto data=serialize(clone,&size);
        for(auto& f:PB::Parse(data,size))if(f.fieldNum==1&&f.wireType==PB::LengthDelimited){
            auto fields=PB::Parse(f.data,f.dataLen);auto id=PB::FindField(fields,2);
            if(id&&id->wireType==PB::Fixed64&&outputCount==sourceIndex)outgoingGameID=id->varintVal;
            outputCount++;
        }
        if(outputCount!=inputCount)outgoingGameID=0;
        lastAttemptedGameID=outgoingGameID;
    }
    bool result=original(cm,wrapper);
    if(games&&clone){
        if(result){
            sent++;lastSentAt=(uint64_t)std::time(nullptr);lastApp=sourceApp;lastGameID=outgoingGameID;
        } else failed++;
    }
    if(clone){memcpy((char*)wrapper+56,&body,8);((void(*)(void*))(*(void***)clone)[1])(clone);}
    if(message==5466&&MetadataSync::AchievementsEnabled())StatsHandlers::ObserveStoreUserStats(input.data(),input.size());
    LivePlaytime::DrainOnNetThread();return result;
}
bool Install(uintptr_t b,size_t size){
    if(installed)return true;if(size<RuntimeProfile::send(b)+32||!RuntimeProfile::Check_send(b)||!RuntimeProfile::Check_parse(b))return false;base=b;
    installed=DobbyHook((void*)(base+RuntimeProfile::send(base)),(void*)&send,(void**)&original)==0;
    if(installed)LOG("[macOS] ARM64 GamesPlayed/presence/stat observer installed");return installed;
}
bool Installed(){return installed.load();}
void Remove(){if(installed)DobbyDestroy((void*)(base+RuntimeProfile::send(base)));installed=false;}
unsigned Observed(){return observed;}unsigned Rewritten(){return rewritten;}
unsigned Sent(){return sent;}unsigned Failed(){return failed;}
uint32_t LastApp(){return lastApp;}uint64_t LastSentAt(){return lastSentAt;}
uint64_t LastGameID(){return lastGameID;}uint64_t LastAttemptedGameID(){return lastAttemptedGameID;}
unsigned TokenRequests(){return tokenRequests;}
}
