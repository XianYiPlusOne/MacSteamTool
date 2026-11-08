// Actual ARM64 Steam and macSteam code in a disposable process. No Steam IPC connection.
#include "vtable_hook.h"
#include "cloud_hooks.h"
#include "cloud_intercept.h"
#include "runtime_settings.h"
#include "access_tokens.h"
#include "presence_apps.h"
#include "presence_shortcuts.h"
#include "runtime_profile.h"
#include "ticket_hooks.h"
#include "gamesplayed_hook.h"
#include "live_playtime.h"
#include "stats_store.h"
#include "stats_handlers.h"
#include "stats_hooks.h"
#include "metadata_sync.h"
#include "json.h"
#include "protobuf.h"
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <thread>
#include <chrono>
#include <sys/stat.h>
extern "C" int DobbyHook(void*,void*,void**);
extern "C" int DobbyDestroy(void*);
extern "C" int FluentCloudInstallHooks();
extern "C" void FluentCloudRemoveHooks();
extern "C" int hook_BYieldingSend(void*,const char*,void*,void*,int*);
static void check(bool ok,const char* why){if(!ok){fprintf(stderr,"FAIL %s\n",why);fflush(nullptr);_Exit(1);}}
static uint64_t fakeID(void* u){uint64_t n;memcpy(&n,(char*)u+0x242,8);return n;}
static int completion=0;
static void complete(void*,const void* data,int size,int callback){check(size==4&&callback==154,"encrypted callback ABI");memcpy(&completion,data,4);}
static uint32_t appWritten=0,lastWritten=0,minutes[4]={},notices=0;
static void lastPlayed(void*,uint64_t app,uint32_t last){appWritten=(uint32_t)app;lastWritten=last;}
static void* mapMinutes(void*,uint64_t app,int create){check(app==480&&create==1,"writer remains scoped");return minutes;}
static void saveMinutes(void*,uint64_t app,void* record){check(app==480&&record==minutes,"native map writer arguments");}
static void notify(void*,int callback,const void*,int size,int){check(callback==1020046&&size==4,"playtime callback ABI");notices++;}
static int passthrough(void*,const char*,void*,void*,int*){return 777;}
static std::vector<uint8_t> serialized(uintptr_t base,void* msg){size_t n=((size_t(*)(void*))(*(void***)msg)[9])(msg);std::vector<uint8_t> out(n);if(n)((void*(*)(void*,void*))(base+0xb3e738))(msg,out.data());return out;}
struct Proto {void* value;void** vt;uintptr_t base;Proto(const char* name,uintptr_t b,size_t size):base(b){vt=VtableHook::FindVtableByRTTIName(name,b,size);check(vt,"protobuf vtable");value=((void*(*)(void*))vt[3])(nullptr);}void parse(const std::vector<uint8_t>& data){static uint8_t empty;check(((int(*)(void*,const void*,int))(base+0xb3e6e8))(value,data.empty()?&empty:data.data(),(int)data.size()),"real protobuf parse");}~Proto(){((void(*)(void*))vt[1])(value);}};
int main(int argc,char** argv){
    check(argc==4,"usage: runtime-probe steamclient macsteam prepared-test-root");std::string root=argv[3];
    check(std::filesystem::exists(root+"/.fluent-fixture"),"explicit disposable fixture marker");
    setenv("FLUENT_CLOUD_ROOT",root.c_str(),1);setenv("FLUENT_CLOUD_STEAM",(root+"/Steam").c_str(),1);
    auto tokenConfig=root+"/macsteam.yaml";setenv("MACSTEAM_CONFIG",tokenConfig.c_str(),1);
    std::ofstream(tokenConfig)<<"Apps:\n  - 480\nFluentAccessTokens:\n  480: 18446744073709551615\n  481: 99\n";
    for(auto invalid:{"Apps:\n  - 480\nFluentAccessTokens:\n  480: 18446744073709551616\n","Apps:\n  - 480\nFluentAccessTokens:\n  480: 1\n  480: 2\n"})check(AccessTokens::Parse(invalid).empty(),"malformed or conflicting token config fails closed");
    check(dlopen(argv[1],RTLD_NOW|RTLD_LOCAL),"load actual Steam");auto mac=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);check(mac,"load installed macSteam");
    check(FluentCloudInstallHooks()==1,"native extension install");
    size_t size=0;auto base=VtableHook::FindSteamclient(size);
    check(StatsStore::WaitForSeed(15000),"cloud statistics seed");
    check(!CloudIntercept::HasNamespaceApps()&&CloudIntercept::IsStatsApp(480)&&!CloudIntercept::IsStatsApp(481),"statistics separated from saves");
    auto c=RuntimeSettings::Current();check(c->tickets.count(480),"ticket validation and private config");auto ticket=c->tickets.at(480);
    alignas(16) unsigned char user[0x6500]={},job[0x200]={},engine[0x1500]={},node[32]={};void* userVT[128]={};userVT[10]=(void*)&fakeID;*(void***)user=userVT;memcpy(user+0x242,&ticket.steamID,8);*(int32_t*)(user+0x6388)=-1;
    *(uint32_t*)(engine+0x130)=1;*(int32_t*)(engine+0x13e0)=0;*(void**)(engine+0x13f8)=node;*(int32_t*)node=-1;*(int32_t*)(node+4)=-1;*(uint32_t*)(node+16)=1;*(uint32_t*)(node+20)=480;
    auto engineGlobal=(void**)(base+0x1876438);auto oldEngine=*engineGlobal;*engineGlobal=engine;
    auto ctor=(void(*)(void*))(base+RuntimeProfile::bufferCtor);auto dtor=(void(*)(void*))(base+RuntimeProfile::bufferDtor);auto put=(void(*)(void*,const void*,int))(base+RuntimeProfile::put);
    alignas(16) unsigned char reader[64]={},writer[64]={};ctor(reader);ctor(writer);uint32_t req[]={480,4096,0};put(reader,req,sizeof(req));
    auto extended=(int(*)(void*,void*,void*))dlsym(mac,"sx_ticket_serve_extended");check(extended&&extended(user,reader,writer)==1,"actual macSteam ownership handler detour");
    auto bytes=*(uint8_t**)writer;uint32_t total=0;memcpy(&total,bytes+1,4);check(bytes[0]==11&&total==ticket.ownership.size()&&!memcmp(bytes+5,ticket.ownership.data(),total),"ownership bytes and framing");
    uint32_t offsets[4]={};memcpy(offsets,bytes+5+4096,16);check(offsets[0]==16&&offsets[1]==8&&offsets[2]==ticket.signature&&offsets[3]==128,"ownership offsets and signature boundary");dtor(reader);dtor(writer);
    unsigned char out[4096]={};uint32_t count=0;auto get=(bool(*)(void*,void*,int,uint32_t*))(base+RuntimeProfile::getETicket);
    check(!get(user,out,1,&count)&&count==ticket.encrypted.size(),"small encrypted buffer rejected");
    check(get(user,out,sizeof(out),&count)&&count==ticket.encrypted.size()&&!memcmp(out,ticket.encrypted.data(),count),"actual Steam encrypted ticket detour");
    auto wrongID=ticket.steamID+1;memcpy(user+0x242,&wrongID,8);check(!get(user,out,sizeof(out),&count),"other account passes through without cached ticket");memcpy(user+0x242,&ticket.steamID,8);
    *(uint32_t*)(node+20)=481;check(!get(user,out,sizeof(out),&count),"unselected app passes through without cached ticket");*(uint32_t*)(node+20)=480;
    void* oldComplete=nullptr;check(!DobbyHook((void*)(base+RuntimeProfile::completeJob),(void*)&complete,&oldComplete),"callback capture boundary");*(uint32_t*)(job+0x16c)=480;*(void**)(job+0x180)=user;
    check(((bool(*)(void*))(base+RuntimeProfile::ticketJob))(job)&&completion==1,"actual ticket job posts callback 154 success");DobbyDestroy((void*)(base+RuntimeProfile::completeJob));*engineGlobal=oldEngine;
    check(TicketHooks::OwnershipServed()==1&&TicketHooks::EncryptedServed()==1&&TicketHooks::CallbacksServed()==1,"ticket hook counters");
    puts("PASS: installed macSteam handler + actual Steam ARM64 encrypted-ticket and async job hooks; exact ticket bytes, offsets, capacity and callback 154 verified.");fflush(stdout);
    // Real typed protobuf objects, a disconnected synthetic CM, no network or Steam IPC.
    Proto games("21CMsgClientGamesPlayed",base,size);unsigned char wrapper[80]={},cm[0x900]={};*(uint32_t*)(wrapper+40)=0x80000000u|5410;*(void**)(wrapper+56)=games.value;
    PB::Writer game,other,body;game.WriteFixed64(2,480);game.WriteString(7,"Spacewar");game.WriteVarint(25,20);other.WriteFixed64(2,481);other.WriteString(7,"Unselected");body.WriteSubmessage(1,game);body.WriteSubmessage(1,other);body.WriteVarint(2,17);games.parse(body.Data());
    std::vector<uint8_t> filtered;check(GamesPlayedHook::FilterPresence(5410,body.Data(),filtered),"selected presence filter");auto fields=PB::Parse(filtered.data(),filtered.size());size_t gameCount=0;for(auto f:fields)if(f.fieldNum==1){gameCount++;auto sub=PB::Parse(f.data,f.dataLen);check(PB::FindField(sub,2)->varintVal==481,"only unselected game remains");}check(gameCount==1&&PB::FindField(fields,2)->varintVal==17,"preserve unrelated fields");
    auto send=(bool(*)(void*,void*))(base+RuntimeProfile::send);check(!send(cm,wrapper),"disconnected original send preserved");check(serialized(base,games.value)==body.Data()&&*(void**)(wrapper+56)==games.value,"caller protobuf restored after filtered send");
    check(GamesPlayedHook::Observed()==1&&GamesPlayedHook::Rewritten()==1,"actual native send detour exercised");
    Proto pics("32CMsgClientPICSProductInfoRequest",base,size);
    PB::Writer app480,app481,package,request;app480.WriteVarint(1,480);app480.WriteVarint(2,1);app480.WriteVarint(3,1);app481.WriteVarint(1,481);app481.WriteVarint(2,22);package.WriteVarint(1,7);package.WriteVarint(2,33);
    request.WriteSubmessage(1,package);request.WriteSubmessage(2,app480);request.WriteSubmessage(2,app481);request.WriteVarint(6,5);pics.parse(request.Data());
    check(RuntimeSettings::Current()->accessTokens.size()==1,"disabled token AppID excluded");
    check(GamesPlayedHook::ApplyAccessTokens(8903,request.Data(),filtered),"PICS access token applied");
    unsigned matched=0;for(auto& f:PB::Parse(filtered.data(),filtered.size())){
        if(f.fieldNum==1){auto sub=PB::Parse(f.data,f.dataLen);check(PB::FindField(sub,2)->varintVal==33,"package token preserved");}
        if(f.fieldNum==2){auto sub=PB::Parse(f.data,f.dataLen);auto id=PB::FindField(sub,1)->varintVal;check(PB::FindField(sub,2)->varintVal==(id==480?UINT64_MAX:22),"selected UInt64 token and unrelated app preserved");matched++;}
    }check(matched==2,"PICS app count preserved");
    *(uint32_t*)(wrapper+40)=0x80000000u|8903;*(void**)(wrapper+56)=pics.value;
    check(!send(cm,wrapper)&&GamesPlayedHook::TokenRequests()==1,"actual Steam typed PICS message traversed token detour");
    check(serialized(base,pics.value)==request.Data()&&*(void**)(wrapper+56)==pics.value,"PICS caller object restored after send");
    std::ofstream(tokenConfig)<<"Apps:\n  - 481\nFluentAccessTokens:\n  480: 18446744073709551615\n";RuntimeSettings::Reload();
    check(!GamesPlayedHook::ApplyAccessTokens(8903,request.Data(),filtered),"disabling app hot-removes token");
    *(uint32_t*)(wrapper+40)=0x80000000u|5410;*(void**)(wrapper+56)=games.value;
    puts("PASS: real ARM64 PICS protobuf and send hook, exact UInt64 access token, package/unselected-app passthrough, caller restoration and hot disable; no network request issued.");
    puts("PASS: actual ARM64 send detour, original AppID observed before presence filtering, unselected 481 and caller protobuf preserved. Measuring one real minute.");fflush(stdout);
    std::this_thread::sleep_for(std::chrono::seconds(61));games.parse({});send(cm,wrapper);
    auto pt=StatsStore::GetPlaytime(480);check(pt.minutesForever>=1&&pt.playtimeWindows>=1,"NotProton Windows session minute recorded");check(StatsStore::GetPlaytime(481).minutesForever==0,"unselected game not tracked");
    StatsStore::SetAchievement(480,0,0,1700000000);StatsStore::SetStat(480,1,7);StatsStore::FlushAll();
    check(StatsStore::Snapshot(480).schema.size()>0,"native Spacewar schema imported from private copy");
    Proto statReq("28CPlayer_GetUserStats_Request",base,size),statResp("29CPlayer_GetUserStats_Response",base,size);
    PB::Writer sr;sr.WriteVarint(2,480);sr.WriteVarint(4,0xffffffff);statReq.parse(sr.Data());CloudHooks::SetOriginals((void*)&passthrough,nullptr,nullptr);int flags[70]={};
    check(hook_BYieldingSend(nullptr,"Player.GetUserStats#1",statReq.value,statResp.value,flags)==1&&flags[3]==1,"stats RPC served with save redirection off");auto response=serialized(base,statResp.value);auto rf=PB::Parse(response.data(),response.size());check(PB::FindField(rf,3)&&PB::FindField(rf,4),"real response includes stats schema and values");
    bool achievement=false;for(auto f:rf)if(f.fieldNum==4&&f.wireType==PB::LengthDelimited){auto stat=PB::Parse(f.data,f.dataLen);auto id=PB::FindField(stat,1);if(id&&id->varintVal==0&&PB::FindField(stat,2)->varintVal==1&&PB::FindField(stat,3))achievement=true;}check(achievement,"achievement bit and unlock timestamp reach native protobuf");
    // A submitted relock must survive cloud merges in either direction.
    StatsStore::StartSession(480,StatsStore::SessionPlatform::Windows);StatsStore::EndSession(480); // persist an older native unlocked bitmap
    StatsStore::ApplySubmittedStats(480,{{0,0}},false);auto cleared=StatsStore::Snapshot(480);
    check(cleared.resetRevision&&cleared.achievements[0].bits==0&&cleared.achievements[0].unlockTimes[0]==0,"submitted relock clears bitmap and timestamp");
    StatsStore::CaptureNativeUnlocks(480);check(StatsStore::Snapshot(480).achievements[0].bits==0,"stale native client flush cannot resurrect a relocked achievement");
    std::string clearJson="{\"reset_revision\":"+std::to_string(cleared.resetRevision)+",\"stats\":[{\"id\":0,\"value\":0,\"merge\":1}],\"achievements\":[{\"stat_id\":0,\"bits\":0}]}";
    std::string staleJson="{\"stats\":[{\"id\":0,\"value\":1,\"merge\":1}],\"achievements\":[{\"stat_id\":0,\"bits\":1}]}";
    for(auto merged:{StatsStore::MergeAppStatsJson(staleJson,clearJson),StatsStore::MergeAppStatsJson(clearJson,staleJson)})check(Json::Parse(merged)["achievements"].arrVal[0]["bits"].integer()==0,"old cloud unlock cannot undo explicit relock");
    StatsStore::ApplySubmittedStats(480,{{0,1}},false);check(StatsStore::Snapshot(480).achievements[0].bits==1,"a later explicit unlock remains possible");pt=StatsStore::GetPlaytime(480);
    puts("PASS: explicit achievement relock has a durable reset revision; stale cloud snapshots cannot resurrect it.");fflush(stdout);
    PB::Writer no;no.WriteVarint(2,481);statReq.parse(no.Data());check(hook_BYieldingSend(nullptr,"Player.GetUserStats#1",statReq.value,statResp.value,flags)==777,"unselected stats passthrough");
    // Drive the real Steam writer, replacing only opaque CUser services with test collectors.
    uintptr_t targets[]={0xa6a084,0xa69a6c,0xa74100,0x5d52a0};void* replacements[]={(void*)&lastPlayed,(void*)&mapMinutes,(void*)&saveMinutes,(void*)&notify};void* tramp[4]={};
    for(int i=0;i<4;i++)check(!DobbyHook((void*)(base+targets[i]),replacements[i],tramp+i),"writer service capture");
    ((uint32_t(*)(void*,void**,int))(base+RuntimeProfile::writePlaytime))(user,nullptr,0);
    auto notification=StatsHandlers::BuildLastPlayedNotificationBody({480,481});LivePlaytime::Apply(notification.Data());
    check(appWritten==480&&lastWritten==pt.lastPlayedTime&&minutes[1]==pt.minutesForever&&notices==1,"real Steam map writer and UI callback consume our protobuf");
    for(auto address:targets)DobbyDestroy((void*)(base+address));
    StatsStore::FlushAll();
    puts("PASS: Windows-platform time accrued; stats RPC and real Steam playtime writer/UI notice validated against private fixtures. No game saves accessed.");fflush(stdout);
    // Compatibility presence uses private shortcut fixtures only. No Steam IPC.
    RuntimeSettings::Stop();MetadataSync::syncPlaytime=false;
    auto runtimeFile=root+"/CloudRedirect/runtime.json";std::filesystem::remove(runtimeFile);
    std::ofstream(tokenConfig)<<"Apps:\n  - 4348910  # 深空当铺\n  - 4348912  # DLC @4348910\n";
    auto account=CloudIntercept::GetAccountId();check(account!=0,"current account available for scoped shortcut lookup");
    auto shortcutFile=[&](uint32_t id){return root+"/Steam/userdata/"+std::to_string(id)+"/config/shortcuts.vdf";};
    auto shortcutBytes=[](const std::vector<uint32_t>& ids){
        std::vector<uint8_t> b;auto str=[&](const std::string& x){b.insert(b.end(),x.begin(),x.end());b.push_back(0);};
        b.push_back(0);str("shortcuts");unsigned index=0;
        for(auto id:ids){b.push_back(0);str(std::to_string(index++));b.push_back(2);str("appid");for(unsigned n=0;n<4;n++)b.push_back(uint8_t(id>>(8*n)));
            b.push_back(1);str("AppName");str("Fixture shortcut");b.push_back(1);str("exe");str("/Fixture/Game");
            b.push_back(0);str("tags");b.push_back(1);str("0");str("appid in a string is not a key");b.push_back(8);b.push_back(8);
        }
        b.push_back(8);b.push_back(8);return b;
    };
    const uint64_t shortcut1=(uint64_t(0x81234567)<<32)|(2ULL<<24),shortcut2=(uint64_t(0x82345678)<<32)|(2ULL<<24);
    auto shortcutData=shortcutBytes({0x81234567,0x82345678});
    check(PresenceShortcuts::Parse(shortcutData)==std::vector<uint64_t>{shortcut1,shortcut2},"binary VDF shortcut IDs remain exact UInt64 values");
    for(size_t n=0;n+1<shortcutData.size();n++)check(PresenceShortcuts::Parse(std::vector<uint8_t>(shortcutData.begin(),shortcutData.begin()+n)).empty(),"truncated binary VDF rejected");
    check(PresenceShortcuts::Parse(shortcutBytes({4348910})).empty(),"ordinary AppID is not a registered shortcut");
    check(PresenceShortcuts::Parse(shortcutBytes({0x81234567,0x81234567})).empty(),"ambiguous duplicate shortcuts rejected");
    auto extraData=shortcutData;extraData.push_back(2);check(PresenceShortcuts::Parse(extraData).empty(),"trailing garbage rejected");
    auto writeShortcut=[&](uint32_t id,const std::vector<uint8_t>& bytes){auto path=shortcutFile(id);std::filesystem::create_directories(std::filesystem::path(path).parent_path());std::ofstream f(path,std::ios::binary);f.write((const char*)bytes.data(),bytes.size());};
    writeShortcut(account+1,shortcutData);RuntimeSettings::Reload();
    check(RuntimeSettings::Current()->presence=="automatic"&&RuntimeSettings::Current()->presenceApps.size()==1&&RuntimeSettings::Current()->presenceApps.count(4348910),"automatic scope is enabled base games, not DLC");
    check(RuntimeSettings::Current()->presenceShortcuts.empty(),"never borrow another account's shortcuts");
    for(auto invalid:{"Apps:\n  - bad\n","Apps:\n  - 4348910\n  - 4348910\n","Apps:\n  - 4294967296\n"})check(PresenceApps::Parse(invalid).empty(),"invalid automatic scope rejected");
    PB::Writer selected,unrelated,autoBody;selected.WriteFixed64(2,4348910);selected.WriteVarint(12,55);selected.WriteVarint(25,20);unrelated.WriteFixed64(2,481);unrelated.WriteVarint(12,99);
    autoBody.WriteSubmessage(1,unrelated);autoBody.WriteSubmessage(1,selected);autoBody.WriteVarint(2,17);
    auto checkOutput=[&](const std::vector<uint8_t>& bytes,uint64_t expected){
        auto values=PB::Parse(bytes.data(),bytes.size());unsigned index=0;
        for(auto& f:values)if(f.fieldNum==1){auto entry=PB::Parse(f.data,f.dataLen);auto id=PB::FindField(entry,2);check(id&&id->varintVal==(index++==0?481:expected),"unselected game preserved and topmost identity selected correctly");
            if(index==1)check(PB::FindField(entry,12)&&PB::FindField(entry,12)->varintVal==99,"unrelated ownership field is unchanged");
            else {auto name=PB::FindField(entry,7);check(name&&std::string((const char*)name->data,name->dataLen)=="深空当铺","localized real title attached to compatibility identity");check(!PB::FindField(entry,12),"shortcut-shaped entry has no borrowed owner");check(PB::FindField(entry,25)->varintVal==20,"platform fields preserved");}
        }
        check(index==2&&PB::FindField(values,2)->varintVal==17,"message metadata and entry count preserved");
    };
    for(auto message:{742u,715u,5410u}){check(GamesPlayedHook::FilterPresence(message,autoBody.Data(),filtered),"compatibility supports all existing GamesPlayed variants");checkOutput(filtered,480);}
    check(!GamesPlayedHook::SuppressRichPresence(4348910),"compatibility rich presence uploads remain native");
    games.parse(autoBody.Data());auto observedBefore=GamesPlayedHook::Observed(),failedBefore=GamesPlayedHook::Failed();
    check(!send(cm,wrapper)&&GamesPlayedHook::Observed()==observedBefore+1,"actual typed send works with time sync disabled");
    check(GamesPlayedHook::LastAttemptedGameID()==480&&GamesPlayedHook::Failed()==failedBefore+1&&GamesPlayedHook::Sent()==0,"typed fallback message is480; disconnected sender is not successful delivery");
    check(serialized(base,games.value)==autoBody.Data()&&*(void**)(wrapper+56)==games.value,"compatibility restores caller-owned protobuf");
    PB::Writer unmanagedTop;unmanagedTop.WriteSubmessage(1,selected);unmanagedTop.WriteSubmessage(1,unrelated);
    check(!GamesPlayedHook::FilterPresence(5410,unmanagedTop.Data(),filtered),"unmanaged game on top defers to Steam");
    writeShortcut(account,shortcutData);RuntimeSettings::Reload();
    check(RuntimeSettings::Current()->presenceShortcuts==std::vector<uint64_t>{shortcut1,shortcut2},"current-account shortcut registration hot-loads");
    check(GamesPlayedHook::FilterPresence(5410,autoBody.Data(),filtered),"registered shortcut preferred to480");checkOutput(filtered,shortcut1);
    games.parse(autoBody.Data());check(!send(cm,wrapper)&&GamesPlayedHook::LastAttemptedGameID()==shortcut1,"actual Steam typed protobuf carries full shortcut GameID");
    check(serialized(base,games.value)==autoBody.Data(),"shortcut send also restores caller-owned protobuf");
    PB::Writer actualShortcut,secondShortcut,actual480,concurrent;
    actualShortcut.WriteFixed64(2,shortcut1);secondShortcut.WriteFixed64(2,shortcut2);actual480.WriteFixed64(2,480);
    concurrent.WriteSubmessage(1,actualShortcut);concurrent.WriteSubmessage(1,selected);
    check(GamesPlayedHook::FilterPresence(5410,concurrent.Data(),filtered),"second registered shortcut used if first is already running");
    auto concurrentFields=PB::Parse(filtered.data(),filtered.size());unsigned i=0;for(auto& f:concurrentFields)if(f.fieldNum==1){auto entry=PB::Parse(f.data,f.dataLen);check(PB::FindField(entry,2)->varintVal==(i++==0?shortcut1:shortcut2),"running shortcut not renamed or replaced");}
    concurrent.WriteSubmessage(1,secondShortcut);concurrent.WriteSubmessage(1,actual480);concurrent.WriteSubmessage(1,selected);
    check(!GamesPlayedHook::FilterPresence(5410,concurrent.Data(),filtered),"all aliases in use do not collapse or impersonate running games");
    std::filesystem::remove(shortcutFile(account));std::filesystem::create_symlink(shortcutFile(account+1),shortcutFile(account));RuntimeSettings::Reload();
    check(RuntimeSettings::Current()->presenceShortcuts.empty(),"symlink shortcut file rejected");std::filesystem::remove(shortcutFile(account));
    writeShortcut(account,shortcutData);RuntimeSettings::Reload();CloudIntercept::SetAccountId(account+2);
    check(GamesPlayedHook::FilterPresence(5410,autoBody.Data(),filtered),"account switch safely falls back until scope refresh");checkOutput(filtered,480);
    CloudIntercept::SetAccountId(account);RuntimeSettings::Reload();
    for(auto mode:{"spacewar","selected"}){
        {std::ofstream file(runtimeFile);file<<"{\"presence\":\""<<mode<<"\",\"presenceApps\":{\"4348910\":\"Old title\"}}";}
        chmod(runtimeFile.c_str(),0600);RuntimeSettings::Reload();
        check(RuntimeSettings::Current()->presence=="selected"&&RuntimeSettings::Current()->presenceApps.at(4348910)=="深空当铺","legacy selection and app-language names preserved");
        check(GamesPlayedHook::FilterPresence(5410,autoBody.Data(),filtered),"selected compatibility works");checkOutput(filtered,shortcut1);
    }
    std::filesystem::remove(runtimeFile);std::ofstream(tokenConfig)<<"Apps:\n  - 483 # Other Game\n";RuntimeSettings::Reload();
    check(!GamesPlayedHook::FilterPresence(5410,autoBody.Data(),filtered),"disabling managed game removes compatibility handling");
    for(auto mode:{"none","unchanged"}){
        {std::ofstream file(runtimeFile);file<<"{\"presence\":\""<<mode<<"\",\"presenceApps\":{\"4348910\":\"深空当铺\"}}";}
        chmod(runtimeFile.c_str(),0600);RuntimeSettings::Reload();check(RuntimeSettings::Current()->presence==mode,"explicit hidden/native choice preserved");
        check(GamesPlayedHook::SuppressRichPresence(4348910)==(std::string(mode)=="none")&&!GamesPlayedHook::SuppressRichPresence(481),"only explicit hidden mode suppresses selected rich presence");
        check(GamesPlayedHook::FilterPresence(5410,autoBody.Data(),filtered)==(std::string(mode)=="none"),"hidden/native behavior unchanged");
    }
    {std::ofstream file(runtimeFile);file<<"{\"presence\":\"automatic\"}";}chmod(runtimeFile.c_str(),0644);RuntimeSettings::Reload();check(RuntimeSettings::Current()->presence=="unchanged","insecure configuration cannot enable broadcasting");
    chmod(runtimeFile.c_str(),0600);{std::ofstream file(runtimeFile);file<<"invalid";}RuntimeSettings::Reload();check(RuntimeSettings::Current()->presence=="unchanged","invalid configuration preserves privacy");
    puts("PASS: upstream-compatible topmost presence: current-account shortcut priority, Spacewar fallback, exact typed GameIDs and localized names, no cross-account or concurrent-game alias collision, owner fields scoped, rich presence pass-through, disabled/native/hidden settings and caller restoration. No network message sent.");fflush(stdout);
    FluentCloudRemoveHooks();puts("PASS: runtime hooks removed; cloud worker shutdown completed.");return 0;
}
