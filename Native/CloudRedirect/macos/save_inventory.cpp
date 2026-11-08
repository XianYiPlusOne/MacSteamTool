#include "save_inventory.h"
#include "autocloud_scan.h"
#include "json.h"
#include "xdg.h"
#include <filesystem>
#include <charconv>
#include <set>
#include <sstream>
#include <stdexcept>

namespace SaveInventory {
namespace fs=std::filesystem;
static uint32_t ID(const std::string& text) {
    uint32_t value=0;auto r=std::from_chars(text.data(),text.data()+text.size(),value);
    return r.ec==std::errc()&&r.ptr==text.data()+text.size()?value:0;
}
std::string Scan(const std::string& appIDs) {
    auto result=Json::Object();result.objVal["success"].type=Json::Type::Bool;
    result.objVal["apps"]=Json::Array();result.objVal["files"]=Json::Array();
    try {
        if(appIDs.size()>65536)throw std::runtime_error("Too many AppIDs");
        std::set<uint32_t> apps;std::istringstream input(appIDs);std::string part;
        while(std::getline(input,part,',')) {auto id=ID(part);if(!id||id>0xffffff||apps.size()>=4096)throw std::runtime_error("Invalid AppID list");apps.insert(id);}
        for(auto app:apps)result.objVal["apps"].arrVal.push_back(Json::Number(app));
        const char* override=getenv("FLUENT_CLOUD_STEAM");
        fs::path steam=override&&override[0]=='/'?override:XdgHome()+"/Library/Application Support/Steam";
        std::set<uint32_t> accounts;
        if(fs::exists(steam/"userdata"))for(const auto& account:fs::directory_iterator(steam/"userdata")) {
            auto id=ID(account.path().filename().string());
            if(id&&account.is_directory()&&!account.is_symlink())accounts.insert(id);
            if(accounts.size()>128)throw std::runtime_error("Too many local accounts");
        }
        // Native saves without a userdata directory can still exist before Steam's first sync.
        if(accounts.empty())accounts.insert(0);
        std::set<std::string> seen;
        auto add=[&](uint32_t app,const fs::path& path) {
            if(fs::is_symlink(path)||!fs::is_regular_file(path))throw std::runtime_error("Save is not a regular file");
            auto canonical=fs::canonical(path).string();
            if(!seen.insert(canonical).second)return;
            if(seen.size()>100000)throw std::runtime_error("Too many save files");
            auto entry=Json::Object();entry.objVal["appID"]=Json::Number(app);entry.objVal["path"]=Json::String(canonical);
            result.objVal["files"].arrVal.push_back(std::move(entry));
        };
        for(auto app:apps)for(auto account:accounts) {
            auto dir=steam/"userdata"/std::to_string(account)/std::to_string(app);
            if(fs::exists(dir/"remotecache.vdf"))add(app,dir/"remotecache.vdf");
            auto remote=dir/"remote";
            if(fs::exists(remote)) {
                if(fs::is_symlink(remote))throw std::runtime_error("Steam remote directory is a symbolic link");
                for(const auto& file:fs::recursive_directory_iterator(remote)) {
                    if(file.is_symlink())throw std::runtime_error("Steam remote contains a symbolic link");
                    if(!file.is_directory())add(app,file.path());
                }
            }
            auto scan=AutoCloudScan::GetFileList(steam.string()+"/",account,app);
            if(!scan.complete||scan.hasRootCollision)throw std::runtime_error("AutoCloud scan incomplete or ambiguous");
            for(const auto& file:scan.files)add(app,file.fullPath);
        }
        result.objVal["success"].boolVal=true;
    } catch(const std::exception&) {
        // Do not expose private game/account paths in an error string.
        result.objVal["error"]=Json::String("Local save inventory failed; check file access, links and AutoCloud rules. Configuration unchanged.");
    }
    return Json::Stringify(result);
}
}
