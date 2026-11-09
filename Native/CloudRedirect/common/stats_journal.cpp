#include "stats_journal.h"
#include "stats_store.h"
#include "sha256_hmac.h"
#include "json.h"
#include "log.h"
#include <algorithm>
#include <chrono>
#include <thread>

namespace StatsJournal {
namespace {
constexpr size_t maxBlob=16*1024*1024,maxRead=128*1024*1024;
bool combine(Json::Value& root,const std::vector<uint8_t>& bytes) {
    if(bytes.size()>maxBlob)return false;
    auto incoming=Json::Parse(std::string(bytes.begin(),bytes.end()));
    if(incoming.type!=Json::Type::Object)return false;
    for(auto& [id,value]:incoming.objVal) {
        if(id.empty()||id.size()>10||id.find_first_not_of("0123456789")!=std::string::npos||value.type!=Json::Type::Object)return false;
        auto merged=Json::Parse(StatsStore::MergeAppStatsJson(root.has(id)?Json::Stringify(root.objVal[id]):std::string(),Json::Stringify(value)));
        if(merged.type!=Json::Type::Object)return false;
        root.objVal[id]=std::move(merged);
    }
    return true;
}
std::string prefix(const std::string& path){return path+".journal/";}
}
bool Read(ICloudProvider& provider,const std::string& path,Snapshot& out) {
    out={};auto root=Json::Object();size_t total=0;
    std::vector<uint8_t> bytes;
    if(provider.Download(path,bytes)) {
        if(!combine(root,bytes))return false;
        total=bytes.size();out.exists=true;
    } else if(provider.CheckExists(path)!=ICloudProvider::ExistsStatus::Missing)return false;
    std::vector<ICloudProvider::FileInfo> files;bool complete=false;
    const auto dir=prefix(path);
    if(!provider.ListChecked(dir,files,&complete)||!complete||files.size()>4096)return false;
    struct Record { int64_t generation;std::string path;std::vector<uint8_t> stats; };
    std::vector<Record> records;
    for(auto& file:files) {
        if(!file.path.starts_with(dir))return false;
        const auto name=file.path.substr(dir.size());
        if(name.size()!=69||name.substr(64)!=".json"||name.substr(0,64).find_first_not_of("0123456789abcdef")!=std::string::npos)return false;
        if(file.size>maxBlob||!provider.Download(file.path,bytes))return false;
        std::string payload(bytes.begin(),bytes.end());
        total+=bytes.size();if(total>maxRead||crypto::Sha256Hex(payload)!=name.substr(0,64))return false;
        auto envelope=Json::Parse(payload);auto generation=envelope["generation"].integer();
        if(envelope["format"].integer()!=1||generation<=0||generation==INT64_MAX||envelope["stats"].type!=Json::Type::Object)return false;
        auto stats=Json::Stringify(envelope["stats"]);
        records.push_back({generation,file.path,std::vector<uint8_t>(stats.begin(),stats.end())});
        out.generation=std::max(out.generation,generation);
        out.included.push_back(file.path);out.exists=true;
    }
    // Causally newer aggregates must win ordinary overwrite statistics even
    // when cleanup fails and old records remain. Concurrent ties are stable.
    std::sort(records.begin(),records.end(),[](auto& a,auto& b){return a.generation==b.generation?a.path<b.path:a.generation<b.generation;});
    for(auto& record:records)if(!combine(root,record.stats))return false;
    out.merged=out.exists?Json::Stringify(root):std::string();
    return out.merged.size()<=maxBlob;
}
bool Publish(ICloudProvider& provider,const std::string& path,const std::function<bool(const std::string&,std::string&)>& merge) {
    Snapshot snapshot;
    // A concurrent compactor can remove a listed snapshot only after another
    // complete snapshot contains it. Re-list instead of accepting a partial read.
    bool read=false;for(int n=0;n<6;n++){if(Read(provider,path,snapshot)){read=true;break;}std::this_thread::sleep_for(std::chrono::milliseconds(25*(n+1)));}
    if(!read)return false;
    std::string merged;if(!merge(snapshot.merged,merged)||merged.size()>maxBlob)return false;
    if(merged==snapshot.merged)return provider.Upload(path,reinterpret_cast<const uint8_t*>(merged.data()),merged.size());
    auto parsed=Json::Parse(merged);if(parsed.type!=Json::Type::Object)return false;
    const auto payload="{\"format\":1,\"generation\":"+std::to_string(snapshot.generation+1)+",\"stats\":"+merged+"}";
    if(payload.size()>maxBlob)return false;
    const auto object=prefix(path)+crypto::Sha256Hex(payload)+".json";
    if(!provider.Upload(object,reinterpret_cast<const uint8_t*>(payload.data()),payload.size()))return false;
    std::vector<uint8_t> verified;
    if(!provider.Download(object,verified)||std::string(verified.begin(),verified.end())!=payload)return false;
    // Compatibility cache for older clients. New clients always merge the
    // immutable records, so a stale cache writer cannot erase concurrent work.
    if(!provider.Upload(path,reinterpret_cast<const uint8_t*>(merged.data()),merged.size())) {
        LOG("[StatsJournal] Snapshot published; cache refresh pending retry");return false;
    }
    // Compact only the exact records included in this verified aggregate.
    // Concurrent publishers' new records were not in the read set and survive.
    for(auto& old:snapshot.included)if(old!=object)provider.Remove(old);
    return true;
}
}
