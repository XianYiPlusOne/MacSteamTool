#pragma once
#include "cloud_provider.h"
#include "file_util.h"
#include "json.h"
#include "sha256_hmac.h"
#include <filesystem>
#include <fstream>
#include <set>
#include <algorithm>
#include <stdexcept>

// Raw-object snapshots for an explicitly selected account/app. No game RPC or
// user save discovery. Every destructive call requires a verified disk backup.
namespace AppDelete {
namespace fs = std::filesystem;
inline void Require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
inline std::string Hash(const std::vector<uint8_t>& bytes){auto h=crypto::Sha256(bytes.data(),bytes.size());return crypto::ToHex(h.data(),h.size());}
inline bool ID(const std::string& s){if(s.empty()||s.size()>10||s.find_first_not_of("0123456789")!=std::string::npos)return false;auto n=strtoull(s.c_str(),nullptr,10);return n>0&&n<UINT32_MAX&&std::to_string(n)==s;}
inline void NoLinks(const fs::path& path){Require(path.is_absolute(),"Absolute backup path required");fs::path part;for(const auto& c:path){part/=c;std::error_code ec;auto st=fs::symlink_status(part,ec);if(ec==std::errc::no_such_file_or_directory)continue;bool alias=false;
#ifdef __APPLE__
if(part=="/var"||part=="/tmp"||part=="/etc"){std::error_code e;alias=fs::canonical(part,e)==fs::path("/private"+part.string())&&!e;}
#endif
Require(!ec&&(!fs::is_symlink(st)||alias),"Symbolic link in backup/source path");}}
inline std::vector<uint8_t> Read(const fs::path& path,size_t limit){NoLinks(path);Require(fs::is_regular_file(path)&&fs::file_size(path)<=limit,"Invalid or oversized backup/input file");std::ifstream f(path,std::ios::binary);Require(bool(f),"Cannot read backup/input file");std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)),{});Require(!f.bad()&&b.size()<=limit,"Incomplete backup/input read");return b;}
inline std::string FileHash(const std::string& path){return fs::exists(path)?Hash(Read(path,4*1024*1024)):"missing";}
inline Json::Value Load(const fs::path& p){auto b=Read(p,8*1024*1024);auto j=Json::Parse(std::string(b.begin(),b.end()));Require(j.type==Json::Type::Object,"Invalid snapshot JSON");return j;}
inline bool Safe(const std::string& path,const std::string& prefix){
    if(!path.starts_with(prefix)||path.size()<=prefix.size()||path.size()>4096||path.find('\\')!=std::string::npos)return false;
    for(unsigned char c:path)if(c<32||c==127)return false;
    size_t start=0;for(size_t end=0;end<=path.size();++end)if(end==path.size()||path[end]=='/'){auto part=path.substr(start,end-start);if(part.empty()||part=="."||part=="..")return false;start=end+1;}
    return true;
}
inline std::vector<ICloudProvider::FileInfo> List(ICloudProvider& p,const std::string& prefix){
    std::vector<ICloudProvider::FileInfo> files;bool complete=false;
    Require(p.ListChecked(prefix,files,&complete)&&complete,"Remote listing is incomplete; nothing deleted");Require(files.size()<=10000,"Too many remote objects");
    std::set<std::string> seen;uint64_t total=0;
    for(auto& f:files){Require(Safe(f.path,prefix)&&seen.insert(f.path).second&&!f.isDeleteMarker,"Invalid or duplicate remote object path");Require(f.size<=256*1024*1024,"Remote object exceeds 256 MiB limit");total+=f.size;Require(total<=uint64_t(2)*1024*1024*1024,"Remote snapshot exceeds 2 GiB limit");}
    std::sort(files.begin(),files.end(),[](auto&a,auto&b){return a.path<b.path;});return files;
}
inline void Match(const std::vector<ICloudProvider::FileInfo>& files,const Json::Value& expected){
    Require(expected.type==Json::Type::Array&&files.size()==expected.size(),"Remote file set changed; refresh preview");
    for(size_t i=0;i<files.size();++i){auto& e=expected[i];Require(e["path"].str()==files[i].path&&e["size"].integer()>=0&&uint64_t(e["size"].integer())==files[i].size&&e["modified_time"].integer()>=0&&uint64_t(e["modified_time"].integer())==files[i].modifiedTime,"Remote file changed; refresh preview");}
}
inline std::string Run(bool deleting,const std::string& provider,const std::string& tokenPath,const std::string& configPath,const std::string& account,const std::string& app,const std::string& input,const std::string& outputOrHash){
    size_t deleted=0;std::unique_ptr<ICloudProvider> p;
    try {
        Require(ID(account)&&ID(app),"Invalid account/app scope");
        fs::path backup=deleting?fs::path(input):fs::path(outputOrHash);
        auto plan=Load(deleting?backup/"receipt.json":fs::path(input));
        if(deleting)Require(FileHash((backup/"receipt.json").string())==outputOrHash,"Backup receipt changed");
        Require(plan["provider"].str()==provider&&plan["account"].str()==account&&plan["app"].str()==app,"Backup scope mismatch");
        Require(plan["tokenPath"].str()==tokenPath&&plan["credentialHash"].str()==FileHash(tokenPath)&&plan["configHash"].str()==FileHash(configPath),"Provider configuration/credentials changed; refresh preview");
        p=CreateCloudProvider(provider);Require(p&&p->Init(tokenPath)&&p->IsAuthenticated(),"Provider initialization/authentication failed");
        const auto prefix=account+"/"+app+"/";auto files=List(*p,prefix);Match(files,plan["files"]);
        if(!deleting){NoLinks(backup);Require(!fs::exists(backup),"Remote backup destination already exists");Require(fs::create_directory(backup),"Cannot create remote backup directory");fs::permissions(backup,fs::perms::owner_all);fs::create_directory(backup/"objects");}
        auto receipt=plan;receipt.objVal["files"]=Json::Array();
        // Complete backup verification and full remote content preflight happen
        // before the first deletion. File names on disk are ordinal, not server paths.
        for(size_t i=0;i<files.size();++i){
            auto disk=backup/"objects"/(std::to_string(i)+".bin");std::vector<uint8_t> data;
            Require(p->Download(files[i].path,data)&&data.size()==files[i].size,"Remote object download/size verification failed");auto sha=Hash(data);
            if(deleting){Require(plan["files"][i]["sha256"].str()==sha&&Hash(Read(disk,256*1024*1024))==sha,"Remote or backup content changed; nothing further deleted");}
            else{Require(FileUtil::AtomicWriteBinary(disk.string(),data.data(),data.size()),"Cannot write remote backup");Require(Hash(Read(disk,256*1024*1024))==sha,"Remote backup readback failed");}
            auto entry=plan["files"][i];entry.objVal["sha256"]=Json::String(sha);receipt.objVal["files"].arrVal.push_back(std::move(entry));
        }
        Match(List(*p,prefix),plan["files"]);
        if(!deleting){Require(FileUtil::AtomicWriteText((backup/"receipt.json").string(),Json::Stringify(receipt)),"Cannot save remote backup receipt");auto result=Json::Object();result.objVal["success"].type=Json::Type::Bool;result.objVal["success"].boolVal=true;result.objVal["receiptHash"]=Json::String(FileHash((backup/"receipt.json").string()));result.objVal["files"]=Json::Number(files.size());p->Shutdown();return Json::Stringify(result);}
        for(size_t i=0;i<files.size();++i){
            std::vector<uint8_t> current;Require(p->Download(files[i].path,current)&&Hash(current)==plan["files"][i]["sha256"].str(),"Remote object changed during deletion");
            Require(p->Remove(files[i].path),"Remote deletion failed; backup retained");++deleted;
        }
        Require(List(*p,prefix).empty(),"Remote objects remain or were newly created; backup retained");p->Shutdown();
        auto result=Json::Object();result.objVal["success"].type=Json::Type::Bool;result.objVal["success"].boolVal=true;result.objVal["deleted"]=Json::Number(deleted);result.objVal["remaining"]=Json::Number(0);return Json::Stringify(result);
    }catch(const std::exception& e){if(p)p->Shutdown();auto result=Json::Object();result.objVal["success"].type=Json::Type::Bool;result.objVal["success"].boolVal=false;result.objVal["deleted"]=Json::Number(deleted);result.objVal["error"]=Json::String(e.what());return Json::Stringify(result);}
}
}
