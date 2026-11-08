#include "presence_apps.h"
#include <regex>
#include <sstream>
#include <fstream>
#include <charconv>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>
namespace PresenceApps {
std::unordered_map<uint32_t,std::string> Parse(const std::string& text) {
    if(text.size()>8*1024*1024)return {};
    std::unordered_map<uint32_t,std::string> apps;
    static const std::regex row(R"(^  -\s+(\d+)(?:\s*#\s*(.*))?\s*$)"), parent(R"(@\d+)");
    std::string section,line;std::istringstream input(text);
    while(std::getline(input,line)) {
        if(!line.empty()&&line.back()=='\r')line.pop_back();
        auto first=line.find_first_not_of(" \t");if(first==std::string::npos||line[first]=='#')continue;
        if(first==0){section=line;continue;}
        if(section!="Apps:")continue;
        std::smatch match;if(!std::regex_match(line,match,row)||apps.size()>=4096)return {};
        auto number=match[1].str();uint32_t id=0;auto parsed=std::from_chars(number.data(),number.data()+number.size(),id);
        if(parsed.ec!=std::errc()||parsed.ptr!=number.data()+number.size()||!id||id>0xffffff||apps.count(id))return {};
        auto name=match[2].str();
        // Same @parent convention as the application's macSteam config writer.
        if(std::regex_search(name,parent))continue;
        auto end=name.find_last_not_of(" \t");name=end==std::string::npos?"":name.substr(0,end+1);
        if(name.size()>512||name.find('\0')!=std::string::npos)return {};
        apps.emplace(id,std::move(name));
    }
    return apps;
}
std::unordered_map<uint32_t,std::string> Read(const std::string& configPath) {
    auto configured=getenv("MACSTEAM_CONFIG");auto home=getenv("HOME");
    std::string path=!configPath.empty()?configPath:configured&&*configured?configured:std::string(home?home:"")+"/Library/Application Support/macsteam/config.yaml";
    struct stat info{};
    if(lstat(path.c_str(),&info)||!S_ISREG(info.st_mode)||info.st_uid!=getuid()||info.st_size>8*1024*1024)return {};
    std::ifstream file(path);return Parse(std::string((std::istreambuf_iterator<char>(file)),{}));
}
}
