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
static void check(bool ok,const char* text){if(!ok){fprintf(stderr,"FAIL %s\n",text);std::exit(1);}}
int main(int argc,char**argv){
    check(argc==3,"schema path and new isolated root required");
    check(!std::filesystem::exists(argv[2]),"isolated root must be new");
    std::filesystem::create_directories(argv[2]);
    MetadataSync::syncAchievements=false;
    StatsStore::SetAccountIdProvider([]{return 1u;});
    StatsStore::Init(argv[2],"");
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
    puts("PASS: installed-game schema bootstrap, missing-schema passthrough, zero-CRC initialization, no foreign unlocks, cached no-op. Isolated storage; no Steam IPC.");
}
