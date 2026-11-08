#include "presence_shortcuts.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <cstring>

namespace PresenceShortcuts {
namespace {
constexpr size_t limit=8*1024*1024;
struct Reader {
    const std::vector<uint8_t>& bytes;size_t pos=0,nodes=0;std::vector<uint64_t> ids;
    bool skip(size_t count){if(count>bytes.size()-pos)return false;pos+=count;return true;}
    bool string(std::string& result){
        size_t start=pos;while(pos<bytes.size()&&bytes[pos]&&pos-start<1024*1024)pos++;
        if(pos==bytes.size()||bytes[pos])return false;
        result.assign((const char*)bytes.data()+start,pos-start);pos++;return true;
    }
    bool object(unsigned depth,bool shortcuts=false,bool entry=false){
        if(depth>16)return false;uint32_t app=0;bool seenApp=false,name=false,executable=false;
        while(pos<bytes.size()){
            auto type=bytes[pos++];if(type==8){
                if(entry&&seenApp&&name&&executable&&(app&0x80000000u)){
                    uint64_t id=(uint64_t(app)<<32)|(2ULL<<24);
                    if(ids.size()>=4096||std::find(ids.begin(),ids.end(),id)!=ids.end())return false;
                    ids.push_back(id);
                }
                return true;
            }
            if(++nodes>200000)return false;std::string key;if(!string(key))return false;
            if(type==0){
                bool child=shortcuts&&!key.empty()&&key.find_first_not_of("0123456789")==std::string::npos;
                if(shortcuts&&!child)return false;
                if(!object(depth+1,false,child))return false;
            } else if(type==1){
                std::string value;if(!string(value))return false;
                if(entry&&key=="AppName")name=!value.empty();
                if(entry&&key=="exe")executable=!value.empty();
            } else if(type==2){
                if(bytes.size()-pos<4)return false;
                if(entry&&key=="appid"){
                    if(seenApp)return false;seenApp=true;
                    app=uint32_t(bytes[pos])|(uint32_t(bytes[pos+1])<<8)|(uint32_t(bytes[pos+2])<<16)|(uint32_t(bytes[pos+3])<<24);
                }
                pos+=4;
            } else if(type==3||type==4||type==6){if(!skip(4))return false;}
            else if(type==7){if(!skip(8))return false;}
            else if(type==5){
                bool end=false;while(bytes.size()-pos>=2){end=bytes[pos]==0&&bytes[pos+1]==0;pos+=2;if(end)break;}if(!end)return false;
            } else return false;
        }
        return false;
    }
};
}
std::vector<uint64_t> Parse(const std::vector<uint8_t>& bytes){
    if(bytes.empty()||bytes.size()>limit||bytes[0]!=0)return {};
    Reader r{bytes};r.pos=1;std::string root;
    if(!r.string(root)||root!="shortcuts"||!r.object(1,true))return {};
    // Binary KV files commonly include a final end marker for the outer list.
    if(r.pos<bytes.size()&&bytes[r.pos]==8)r.pos++;
    return r.pos==bytes.size()?r.ids:std::vector<uint64_t>{};
}
std::vector<uint64_t> Read(const std::string& steamRoot,uint32_t account){
    if(!account||steamRoot.empty())return {};
    auto path=steamRoot+"/userdata/"+std::to_string(account)+"/config/shortcuts.vdf";
    int fd=open(path.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return {};
    struct stat info{};
    if(fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_uid!=getuid()||info.st_size<=0||info.st_size>limit){close(fd);return {};}
    std::vector<uint8_t> bytes((size_t)info.st_size);size_t offset=0;
    while(offset<bytes.size()){auto n=read(fd,bytes.data()+offset,bytes.size()-offset);if(n<=0){close(fd);return {};}offset+=(size_t)n;}
    close(fd);return Parse(bytes);
}
}
