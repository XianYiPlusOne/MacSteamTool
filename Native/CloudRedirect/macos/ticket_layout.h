#pragma once
#include <cstdint>
#include <cstring>
#include <vector>
namespace TicketLayout {
inline bool Locate(const std::vector<uint8_t>& bytes, uint32_t app, uint32_t& offset, uint32_t& signature, uint64_t& steam) {
    if (!app || bytes.size()<148 || bytes.size()>4096) return false;
    auto read=[&](size_t p){uint32_t n;std::memcpy(&n,bytes.data()+p,4);return n;};
    std::memcpy(&steam,bytes.data()+8,8); if(!steam)return false;
    signature=uint32_t(bytes.size()-128);
    if(read(4)==4){offset=read(0);return offset>=16 && offset<=signature-4 && read(offset)==app;}
    if(read(0)!=signature || signature<20)return false;
    if(read(16)==app){offset=16;return true;}
    unsigned hits=0;for(uint32_t p=16;p+4<=signature;++p)if(read(p)==app){offset=p;++hits;}
    return hits==1;
}
}
