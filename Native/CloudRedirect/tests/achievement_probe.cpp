// Definitions from an installed game, but all state/storage are disposable.
// No Steam IPC connection and no achievement writes to a real account.
#include "stats_store.h"
#include "stats_handlers.h"
#include "metadata_sync.h"
#include "protobuf.h"
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <cstdlib>
#include <cstring>
static void section(std::vector<uint8_t>& out,const char* name){out.push_back(0);out.insert(out.end(),name,name+strlen(name)+1);}
static void number(std::vector<uint8_t>& out,const char* name,uint32_t value){out.push_back(2);out.insert(out.end(),name,name+strlen(name)+1);for(int i=0;i<4;i++)out.push_back((value>>(8*i))&255);}
static void nativeStats(const std::filesystem::path& dir,uint32_t timestamp){
    std::vector<uint8_t> data;section(data,"cache");section(data,"3");number(data,"data",1);
    section(data,"AchievementTimes");number(data,"0",timestamp);
    data.insert(data.end(),{8,8,8,8});
    std::ofstream out(dir/"UserGameStats_1_4348910.bin",std::ios::binary);out.write((const char*)data.data(),data.size());
}
static void check(bool ok,const char* text){if(!ok){fprintf(stderr,"FAIL %s\n",text);std::exit(1);}}
int main(int argc,char**argv){
    check(argc==3,"schema path and new isolated root required");
    check(!std::filesystem::exists(argv[2]),"isolated root must be new");
    std::filesystem::create_directories(argv[2]);
    MetadataSync::syncAchievements=false;
    StatsStore::SetAccountIdProvider([]{return 1u;});
    auto steam=std::filesystem::path(argv[2])/"Steam",cache=steam/"appcache"/"stats";
    std::filesystem::create_directories(cache);
    StatsStore::Init(argv[2],steam.string());
    PB::Writer req;req.WriteVarint(2,4348910);req.WriteVarint(4,0);
    auto fields=PB::Parse(req.Data().data(),req.Size());
    check(StatsHandlers::HandleGetUserStats(4348910,fields).body.Size()==0,"missing schema must pass through, not return success");
    std::ifstream file(argv[1],std::ios::binary);std::vector<uint8_t> schema((std::istreambuf_iterator<char>(file)),{});
    check(!schema.empty(),"installed-game schema available");
    StatsStore::SetSchema(4348910,schema.data(),schema.size());
    auto fresh=StatsHandlers::HandleGetUserStats(4348910,fields);auto response=PB::Parse(fresh.body.Data().data(),fresh.body.Size());
    check(PB::FindField(response,3)&&PB::FindField(response,3)->dataLen==schema.size(),"CRC zero bootstrap sends schema");
    check(!PB::FindField(response,4),"public schema does not import source-user unlocks");
    req.WriteString(3,"known-schema");fields=PB::Parse(req.Data().data(),req.Size());
    auto cached=StatsHandlers::HandleGetUserStats(4348910,fields);response=PB::Parse(cached.body.Data().data(),cached.body.Size());
    check(PB::FindField(response,2)&&!PB::FindField(response,3),"matching CRC and known schema remain a no-op");
    std::filesystem::copy_file(argv[1],cache/"UserGameStatsSchema_4348910.bin");
    StatsStore::SetAchievement(4348910,3,0,1700000000);
    nativeStats(cache,1700000000);
    StatsStore::ApplySubmittedStats(4348910,{{3,0}},false);
    auto cleared=StatsStore::Snapshot(4348910);
    check(cleared.resetRevision&&cleared.achievements[0].bits==0,"explicit relock recorded");
    StatsStore::CaptureNativeUnlocks(4348910);
    check(StatsStore::Snapshot(4348910).achievements[0].bits==0,"old cached unlock cannot resurrect a relock");
    auto freshTime=(uint32_t)(cleared.resetRevision/1000000+1);
    nativeStats(cache,freshTime);
    StatsStore::CaptureNativeUnlocks(4348910);
    auto earned=StatsStore::Snapshot(4348910);
    check(earned.achievements[0].bits==1&&earned.achievements[0].unlockTimes[0]==freshTime,"later in-game native unlock survives earlier relock without a network StoreStats message");
    puts("PASS: installed-game schema bootstrap, missing-schema passthrough, zero-CRC initialization, no foreign unlocks, cached no-op. Isolated storage; no Steam IPC.");
    puts("PASS: stale native unlock rejected; a genuinely later game unlock is captured without management-worker or network submission.");
}
