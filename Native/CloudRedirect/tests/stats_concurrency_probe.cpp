#include "local_disk_provider.h"
#include "stats_journal.h"
#include "stats_store.h"
#include "json.h"
#include <atomic>
#include <barrier>
#include <thread>
#include <mutex>
#include <filesystem>
#include <cstdio>
#include <cstdlib>
static void check(bool ok,const char* message){if(!ok){fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}}
struct JournalProvider:LocalDiskProvider {
    inline static std::mutex storage;
    std::barrier<>* gate=nullptr;bool partial=false,failUpload=false,failRemove=false;std::atomic<bool> entered{false};
    bool UsesImmutableStats() const override{return true;}
    bool Upload(const std::string& path,const uint8_t* bytes,size_t size) override {
        if(failUpload)return false;
        if(gate&&path.find(".journal/")!=std::string::npos&&!entered.exchange(true))gate->arrive_and_wait();
        std::lock_guard lock(storage); // Models the provider's atomic single-object replacement.
        return LocalDiskProvider::Upload(path,bytes,size);
    }
    bool ListChecked(const std::string& prefix,std::vector<FileInfo>& out,bool* complete) override {
        auto result=LocalDiskProvider::ListChecked(prefix,out,complete);if(partial&&complete)*complete=false;return result;
    }
    bool Remove(const std::string& path) override {return !failRemove&&LocalDiskProvider::Remove(path);}
};
static std::string stats(int bits,const char* device,int minutes,int reset=0){return "{\"reset_revision\":"+std::to_string(reset)+",\"stats\":[{\"id\":3,\"value\":"+std::to_string(bits)+",\"merge\":1}],\"achievements\":[{\"stat_id\":3,\"bits\":"+std::to_string(bits)+"}],\"playtime\":{\"per_device\":{\""+device+"\":{\"windows\":"+std::to_string(minutes)+"}}}}";}
static auto merger(const std::string& addition){return [addition](const std::string& current,std::string& out){auto root=current.empty()?Json::Object():Json::Parse(current);if(root.type!=Json::Type::Object)return false;root.objVal["900004"]=Json::Parse(StatsStore::MergeAppStatsJson(root.has("900004")?Json::Stringify(root.objVal["900004"]):std::string(),addition));out=Json::Stringify(root);return true;};}
int main(int argc,char**argv){
    check(argc==2&&!std::filesystem::exists(argv[1]),"new disposable root required");
    std::filesystem::create_directories(argv[1]);const std::string root=argv[1],path="12345/0/stats.json";
    LocalDiskProvider a,b;check(a.Init(root+"/folder")&&b.Init(root+"/folder"),"folder providers ready");
    std::vector<uint8_t> bytes;std::string va,vb;
    check(a.ReadVersioned(path,bytes,va)==ICloudProvider::ExistsStatus::Missing&&b.ReadVersioned(path,bytes,vb)==ICloudProvider::ExistsStatus::Missing,"both readers see missing");
    std::barrier gate(2);ICloudProvider::ConditionalResult ra,rb;
    std::thread ta([&]{gate.arrive_and_wait();ra=a.WriteConditional(path,"A",va);});
    std::thread tb([&]{gate.arrive_and_wait();rb=b.WriteConditional(path,"B",vb);});ta.join();tb.join();
    check((ra==ICloudProvider::ConditionalResult::Written)!=(rb==ICloudProvider::ConditionalResult::Written),"only one simultaneous create wins");
    check(ra==ICloudProvider::ConditionalResult::Conflict||rb==ICloudProvider::ConditionalResult::Conflict,"stale create rejected");
    check(a.ReadVersioned(path,bytes,va)==ICloudProvider::ExistsStatus::Exists,"read exact existing version");
    check(a.WriteConditional(path,"next",va)==ICloudProvider::ConditionalResult::Written,"matching version written");
    check(b.WriteConditional(path,"stale",va)==ICloudProvider::ConditionalResult::Conflict,"stale update rejected");
    JournalProvider ja,jb;check(ja.Init(root+"/journal")&&jb.Init(root+"/journal"),"journal providers ready");
    std::barrier publish(2);ja.gate=&publish;jb.gate=&publish;bool oka=false,okb=false;
    std::thread pa([&]{oka=StatsJournal::Publish(ja,path,merger(stats(1,"device-a",3)));});
    std::thread pb([&]{okb=StatsJournal::Publish(jb,path,merger(stats(2,"device-b",5)));});pa.join();pb.join();
    check(oka&&okb,"simultaneous immutable publishers succeed");
    StatsJournal::Snapshot snapshot;check(StatsJournal::Read(ja,path,snapshot),"fresh journal reader merges both writers");
    auto parsed=Json::Parse(snapshot.merged)["900004"];
    check(parsed["achievements"][size_t(0)]["bits"].integer()==3,"both simultaneous achievements retained");
    check(parsed["playtime"]["windows"].integer()==8,"both device durations retained exactly once");
    auto old=snapshot.merged;
    check(StatsJournal::Publish(ja,path,merger(stats(4,"device-c",7))),"verified aggregate compacts observed records");
    check(StatsJournal::Read(jb,path,snapshot)&&snapshot.included.size()==1,"compaction keeps bounded snapshots");
    check(Json::Parse(snapshot.merged)["900004"]["achievements"][size_t(0)]["bits"].integer()==7,"compaction retains all three achievements");
    ja.failRemove=true;
    auto newer=Json::Object();newer.objVal["stats"]=Json::Parse("[{\"id\":4,\"value\":42}]");
    check(StatsJournal::Publish(ja,path,merger(Json::Stringify(newer))),"new ordinary statistic published while cleanup fails");
    newer.objVal["stats"]=Json::Parse("[{\"id\":4,\"value\":12}]");
    check(StatsJournal::Publish(ja,path,merger(Json::Stringify(newer))),"later decreasing statistic published");
    check(StatsJournal::Read(jb,path,snapshot),"retained generations readable");
    auto current=Json::Parse(snapshot.merged);bool found=false;for(auto& entry:current["900004"]["stats"].arrVal)if(entry["id"].integer()==4){found=true;check(entry["value"].integer()==12,"latest generation wins even when numeric value decreases");}
    check(found,"ordinary statistic retained");ja.failRemove=false;
    check(StatsJournal::Publish(ja,path,merger(stats(0,"device-c",7,10))),"reset snapshot published");
    ja.Upload(path,reinterpret_cast<const uint8_t*>(old.data()),old.size());
    check(StatsJournal::Read(jb,path,snapshot)&&Json::Parse(snapshot.merged)["900004"]["reset_revision"].integer()==10,"stale legacy cache cannot undo reset");
    check(Json::Parse(snapshot.merged)["900004"]["achievements"][size_t(0)]["bits"].integer()==0,"reset does not resurrect unlocks");
    ja.partial=true;check(!StatsJournal::Read(ja,path,snapshot)&&!StatsJournal::Publish(ja,path,merger(stats(8,"d",1))),"partial listing cannot acknowledge or overwrite progress");
    ja.partial=false;ja.failUpload=true;check(!StatsJournal::Publish(ja,path,merger(stats(8,"d",1,10))),"failed publication remains unacknowledged");
    std::filesystem::remove_all(root);
    puts("PASS: Folder stale create/update CAS; simultaneous Drive-style immutable publications retain achievements and duration; verified compaction, reset/old-cache replay, incomplete listings and offline failure. Only disposable data used.");
}
