#include "access_tokens.h"
#include <regex>
#include <sstream>
#include <fstream>
#include <unordered_set>
#include <charconv>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>
namespace AccessTokens {
namespace {
uint64_t number(const std::string& text) {
    uint64_t value=0;auto result=std::from_chars(text.data(),text.data()+text.size(),value);
    return result.ec==std::errc()&&result.ptr==text.data()+text.size()?value:0;
}
}
std::unordered_map<uint32_t,uint64_t> Parse(const std::string& text) {
    if(text.size()>8*1024*1024)return {};
    std::unordered_set<uint32_t> apps;std::unordered_map<uint32_t,uint64_t> tokens;
    static const std::regex app(R"(^  -\s+(\d+)\s*(?:#.*)?$)"), token(R"(^  (\d+):\s*(\d+)\s*(?:#.*)?$)");
    std::string section,line;std::istringstream input(text);
    while(std::getline(input,line)) {
        if(!line.empty()&&line.back()=='\r')line.pop_back();
        auto first=line.find_first_not_of(" \t");if(first==std::string::npos||line[first]=='#')continue;
        if(first==0){section=line;continue;}
        std::smatch m;
        if(section=="Apps:") {
            if(!std::regex_match(line,m,app))return {};
            auto id=number(m[1]);if(!id||id>UINT32_MAX)return {};apps.insert((uint32_t)id);
        } else if(section=="FluentAccessTokens:") {
            if(!std::regex_match(line,m,token)||tokens.size()>=4096)return {};
            auto id=number(m[1]),value=number(m[2]);
            if(!id||id>UINT32_MAX||!value||tokens.count((uint32_t)id))return {};
            tokens[(uint32_t)id]=value;
        }
    }
    for(auto i=tokens.begin();i!=tokens.end();)if(!apps.count(i->first))i=tokens.erase(i);else ++i;
    return tokens;
}
std::unordered_map<uint32_t,uint64_t> Read() {
    auto configured=getenv("MACSTEAM_CONFIG");auto home=getenv("HOME");
    std::string path=configured&&*configured?configured:std::string(home?home:"")+"/Library/Application Support/macsteam/config.yaml";
    struct stat info{};
    if(lstat(path.c_str(),&info)||!S_ISREG(info.st_mode)||info.st_uid!=getuid()||info.st_size>8*1024*1024)return {};
    std::ifstream file(path);return Parse(std::string((std::istreambuf_iterator<char>(file)),{}));
}
}
