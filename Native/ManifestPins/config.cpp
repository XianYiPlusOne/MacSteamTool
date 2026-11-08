#include "pins.h"
#include <fstream>
#include <sstream>
#include <vector>
#include <map>
#include <set>
#include <cstring>
#include <charconv>
#include <stdexcept>
#include <mutex>
#include <optional>
#include <sys/stat.h>
#include <zlib.h>
namespace {
std::string read(const std::string& path, size_t limit) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f || f.tellg() < 0 || static_cast<uint64_t>(f.tellg()) > limit) throw std::runtime_error("missing or oversized file");
    std::string text(static_cast<size_t>(f.tellg()), '\0'); f.seekg(0);
    if (!f.read(text.data(), text.size())) throw std::runtime_error("short read");
    return text;
}
uint64_t number(std::string_view text) {
    uint64_t value = 0; auto r = std::from_chars(text.data(), text.data()+text.size(), value);
    if (text.empty() || r.ec != std::errc() || r.ptr != text.data()+text.size()) throw std::runtime_error("invalid unsigned integer");
    return value;
}
uint32_t u32(const std::string& text, size_t at) {
    if (at > text.size() || text.size()-at < 4) throw std::runtime_error("truncated frame");
    uint32_t value; std::memcpy(&value, text.data()+at, 4); return value;
}
FluentPins::Pin manifest(const std::string& file, uint32_t depot, uint64_t gid) {
    auto text = read(file, 128*1024*1024); size_t offset=0; bool ended=false;
    std::map<uint32_t,std::string_view> sections; uint32_t payloadCRC=0;
    while (offset < text.size()) {
        auto type=u32(text,offset); offset+=4;
        if(type==0x32c415ab){ended=true;break;}
        if(type!=0x71f617d0 && type!=0x1f4812be && type!=0x1b81b817) throw std::runtime_error("unknown section");
        auto length=u32(text,offset);offset+=4;
        if(length>text.size()-offset || sections.count(type))throw std::runtime_error("invalid section");
        sections[type]=std::string_view(text).substr(offset,length);
        if(type==0x71f617d0)payloadCRC=static_cast<uint32_t>(crc32(0,reinterpret_cast<const Bytef*>(text.data()+offset-4),length+4));
        offset+=length;
    }
    if(!ended || offset!=text.size() || sections.size()!=3)throw std::runtime_error("incomplete manifest");
    auto meta=sections.at(0x1f4812be);size_t i=0;std::map<unsigned,uint64_t> fields;
    auto varint=[&](){
        uint64_t n=0;
        for(unsigned shift=0;shift<=63;shift+=7){
            if(i>=meta.size())throw std::runtime_error("truncated metadata");
            unsigned char b=meta[i++];if(shift==63 && b>1)throw std::runtime_error("integer overflow");
            n|=uint64_t(b&127)<<shift;if(!(b&128))return n;
        }
        throw std::runtime_error("invalid varint");
    };
    while(i<meta.size()){
        auto tag=varint();auto field=tag>>3;if(!field || field>0x1fffffff)throw std::runtime_error("invalid field");
        switch(tag&7){
            case 0: if(fields.count(field))throw std::runtime_error("duplicate metadata");fields[field]=varint();break;
            case 1: i+=8;break;
            case 2: {auto count=varint();if(count>meta.size()-i)throw std::runtime_error("invalid length");i+=count;break;}
            case 5: i+=4;break;
            default:throw std::runtime_error("invalid wire type");
        }
        if(i>meta.size())throw std::runtime_error("truncated field");
    }
    auto crc=fields[fields[4]?8:9];
    if(fields[1]!=depot || fields[2]!=gid || !fields.count(5) || (crc && crc!=payloadCRC))throw std::runtime_error("manifest identity / CRC mismatch");
    return {gid,fields[5]};
}
}
FluentPins::Pins FluentPins::Read(const std::string& config,const std::string& depotCache) {
    // Revalidate only files whose inode, size or nanosecond timestamp changed.
    // Steam may consult the depot helper often; its detour only reads an atomic map.
    struct Cached { std::string stamp; std::optional<Pin> pin; };
    static std::map<std::string,Cached> previous;
    static std::mutex cacheMutex;
    std::lock_guard<std::mutex> cacheLock(cacheMutex);
    std::map<std::string,Cached> updated;
    auto stamp=[](const std::string& path){
        struct stat s{};if(stat(path.c_str(),&s)!=0 || !S_ISREG(s.st_mode))return std::string("missing");
        return std::to_string(s.st_dev)+":"+std::to_string(s.st_ino)+":"+std::to_string(s.st_size)+":"+std::to_string(s.st_mtimespec.tv_sec)+":"+std::to_string(s.st_mtimespec.tv_nsec);
    };
    Pins pins;
    try {
        std::istringstream lines(read(config,8*1024*1024));std::string line,section;uint64_t owner=0;
        std::set<uint32_t> apps;std::map<uint32_t,std::pair<uint32_t,uint64_t>> declared;
        while(std::getline(lines,line)){
            if(!line.empty() && line.back()=='\r')line.pop_back();
            auto end=line.find('#');if(end!=std::string::npos)line.resize(end);
            while(!line.empty() && line.back()==' ')line.pop_back();
            auto indent=line.find_first_not_of(' ');if(indent==std::string::npos)continue;
            auto value=line.substr(indent);
            if(indent==0){section=value;owner=0;continue;}
            if(section=="Apps:" && indent==2 && value.starts_with("- ")){
                auto id=number(value.substr(2));if(!id || id>UINT32_MAX)throw std::runtime_error("invalid app");apps.insert(id);
            }
            if(section!="FluentManifestPins:")continue;
            if(indent==2 && value.ends_with(':')){owner=number(value.substr(0,value.size()-1));if(!owner || owner>UINT32_MAX)throw std::runtime_error("invalid owner");continue;}
            auto colon=value.find(": ");
            if(indent!=4 || !owner || colon==std::string::npos)throw std::runtime_error("invalid pin");
            auto depot=number(value.substr(0,colon)),gid=number(value.substr(colon+2));
            if(!depot || depot>UINT32_MAX || !gid || declared.count(depot))throw std::runtime_error("conflicting pin");
            declared[depot]={owner,gid};if(declared.size()>4096)throw std::runtime_error("too many pins");
        }
        for(auto [depot,entry]:declared)if(apps.count(entry.first)){
            auto file=depotCache+"/"+std::to_string(depot)+"_"+std::to_string(entry.second)+".manifest";
            auto version=stamp(file);auto cached=previous.find(file);Cached item{version,std::nullopt};
            if(cached!=previous.end() && cached->second.stamp==version)item=cached->second;
            else if(version!="missing"){
                try {auto value=manifest(file,depot,entry.second);if(stamp(file)==version)item.pin=value;}
                catch(...){} // A missing/corrupt cache cannot redirect to an unverified version.
            }
            if(item.pin)pins[depot]=*item.pin;
            updated[file]=std::move(item);
        }
    } catch(...) {pins.clear();}
    previous=std::move(updated);
    return pins;
}
